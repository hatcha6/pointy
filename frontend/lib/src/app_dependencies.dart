import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;

import 'core/analytics_device_profile.dart';
import 'core/analytics_engine.dart';
import 'core/result.dart';
import 'core/revalidation.dart';
import 'core/server_state.dart';
import 'data/models/analytics_event.dart';
import 'data/models/device_settings.dart';
import 'data/repositories/ai_chat_repository.dart';
import 'data/repositories/analytics_repository.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/crm_repository.dart';
import 'data/repositories/messaging_repository.dart';
import 'data/repositories/business_alert_repository.dart';
import 'data/repositories/attendance_repository.dart';
import 'data/repositories/migration_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/companion_repository.dart';
import 'data/repositories/contact_repository.dart';
import 'data/repositories/dashboard_repository.dart';
import 'data/repositories/device_settings_repository.dart';
import 'data/repositories/discount_repository.dart';
import 'data/repositories/document_trail_repository.dart';
import 'data/repositories/employee_repository.dart';
import 'data/repositories/expense_repository.dart';
import 'data/repositories/fraud_repository.dart';
import 'data/repositories/inventory_repository.dart';
import 'data/repositories/operations_repository.dart';
import 'data/repositories/modifier_group_repository.dart';
import 'data/repositories/payments_repository.dart';
import 'data/repositories/treasury_repository.dart';
import 'data/repositories/price_checker_repository.dart';
import 'data/repositories/scales_repository.dart';
import 'data/repositories/surveillance_repository.dart';
import 'features/dashboard/view_models/dashboard_cameras_view_model.dart';
import 'features/dashboard/view_models/dashboard_fx_view_model.dart';
import 'data/repositories/printing_repository.dart';
import 'data/repositories/purchase_repository.dart';
import 'data/repositories/register_session_repository.dart';
import 'data/repositories/warehouse_repository.dart';
import 'data/repositories/report_repository.dart';
import 'data/repositories/prep_station_repository.dart';
import 'data/repositories/sale_repository.dart';
import 'data/repositories/sales_channel_repository.dart';
import 'data/repositories/shop_settings_repository.dart';
import 'data/repositories/stock_count_repository.dart';
import 'data/repositories/tracked_stock_repository.dart';
import 'features/inventory/view_models/tracked_stock_view_model.dart';
import 'data/repositories/fx_repository.dart';
import 'data/repositories/subscription_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/services/backend_discovery_service.dart';
import 'data/services/client_update_service.dart';
import 'data/services/connection_coordinator.dart';
import 'data/services/connection_profile_storage.dart';
import 'data/services/connection_status_controller.dart';
import 'data/services/pos_api_service.dart';
import 'data/services/server_state_watcher.dart';
import 'data/services/pos_http_client.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/companion/companion_bridge.dart';
import 'features/activity_log/view_models/activity_log_view_model.dart';
import 'features/reports/view_models/reports_view_model.dart';
import 'features/contacts/view_models/contact_management_view_model.dart';
import 'features/crm/view_models/campaigns_view_model.dart';
import 'features/crm/view_models/conversations_view_model.dart';
import 'features/dashboard/view_models/dashboard_view_model.dart';
import 'features/device_settings/view_models/device_settings_view_model.dart';
import 'features/discounts/view_models/discount_management_view_model.dart';
import 'features/attendance/view_models/attendance_view_model.dart';
import 'features/migration/view_models/migration_view_model.dart';
import 'features/employees/view_models/employee_payroll_view_model.dart';
import 'features/notifications/view_models/notification_center_view_model.dart';
import 'features/pos/view_models/pos_revalidation.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/printing/view_models/printing_settings_view_model.dart';
import 'features/invoices/view_models/invoice_list_view_model.dart';
import 'features/learning/view_models/learning_view_model.dart';
import 'features/purchasing/view_models/purchase_order_list_view_model.dart';
import 'features/purchasing/view_models/purchase_view_model.dart';
import 'features/stock_count/view_models/stock_count_sessions_view_model.dart';
import 'features/user_settings/view_models/user_settings_view_model.dart';
import 'shared/barcode/scan_feedback_sounds.dart';
import 'shared/price_checker/price_checker_mode_controller.dart';
import 'shared/theme/theme_controller.dart';
import 'core/authorization.dart';

/// Default API base URL for a fresh install.
///
/// On the web the app is served by the on-prem server itself (nginx serves the
/// Flutter build and reverse-proxies `/api` to the backend), so the API lives at
/// the same origin the page was loaded from. Browsers cannot run the UDP
/// discovery the native apps use, so this same-origin default is how the served
/// web build finds its backend with no configuration. Native builds keep the
/// loopback default and then discover the real LAN backend.
String defaultApiBaseUrl() {
  if (kIsWeb) {
    return '${Uri.base.origin}/api';
  }
  return 'http://127.0.0.1:8000/api';
}

class PointyAppDependencies {
  PointyAppDependencies({
    PosApiService? apiService,
    bool? enableAutomaticConnection,
  }) : service = apiService ?? PosApiService(baseUrl: defaultApiBaseUrl()),
       _enableAutomaticConnection =
           enableAutomaticConnection ?? apiService == null {
    analyticsRepository = AnalyticsRepository(service);
    analyticsEngine = AnalyticsEngine(
      analyticsRepository,
      // The installation id is only known once the engine has started; stamp it
      // on the API session then, so even a rejected request identifies its
      // device instead of arriving anonymous. The version arrives the same way
      // and can arrive twice: a build with no `POINTY_VERSION` define falls
      // back to the bundle's own version, which is resolved asynchronously.
      onIdentityResolved: (deviceId, platform, appVersion) =>
          service.describeClient(
            deviceId: deviceId,
            platform: platform,
            appVersion: appVersion,
          ),
      // Reads the machine once per launch — version, RAM, CPU, screen — for
      // `app.started`. Injected rather than imported by the engine, which also
      // has to build for the web, where none of it exists.
      deviceProfile: resolveAnalyticsDeviceProfile,
    );
    service.performanceRecorder = analyticsEngine.recordApiRequest;
    attendanceRepository = AttendanceRepository(service);
    migrationRepository = MigrationRepository(service);
    authRepository = AuthRepository(service);
    catalogRepository = CatalogRepository(service);
    contactRepository = ContactRepository(service);
    dashboardRepository = DashboardRepository(service);
    deviceSettingsRepository = const DeviceSettingsRepository();
    themeController = ThemeController();
    priceCheckerModeController = PriceCheckerModeController();
    companionRepository = CompanionRepository(service);
    businessAlertRepository = BusinessAlertRepository(service);
    discountRepository = DiscountRepository(service);
    documentTrailRepository = DocumentTrailRepository(service);
    employeeRepository = EmployeeRepository(service);
    expenseRepository = ExpenseRepository(service);
    fraudRepository = FraudRepository(service);
    inventoryRepository = InventoryRepository(service);
    operationsRepository = OperationsRepository(service);
    registerSessionRepository = RegisterSessionRepository(service);
    reportRepository = ReportRepository(service);
    saleRepository = SaleRepository(service);
    salesChannelRepository = SalesChannelRepository(service);
    warehouseRepository = WarehouseRepository(service);
    prepStationRepository = PrepStationRepository(service);
    modifierGroupRepository = ModifierGroupRepository(service);
    shopSettingsRepository = ShopSettingsRepository(service);
    printingRepository = PrintingRepository(service);
    priceCheckerRepository = PriceCheckerRepository(service);
    surveillanceRepository = SurveillanceRepository(service);
    scalesRepository = ScalesRepository(service);
    dashboardCamerasViewModel = DashboardCamerasViewModel(
      surveillanceRepository,
    );
    aiChatRepository = AiChatRepository(service);
    purchaseRepository = PurchaseRepository(service);
    paymentsRepository = PaymentsRepository(service);
    treasuryRepository = TreasuryRepository(service);
    stockCountRepository = StockCountRepository(service);
    trackedStockRepository = TrackedStockRepository(service);
    trackedStockViewModel = TrackedStockViewModel(trackedStockRepository);
    subscriptionRepository = SubscriptionRepository(service);
    fxRepository = FxRepository(service);
    dashboardFxViewModel = DashboardFxViewModel(fxRepository);
    messagingRepository = MessagingRepository(service);
    crmRepository = CrmRepository(service);
    userRepository = UserRepository(service);
    connectionStatus = ConnectionStatusController();
    connectionCoordinator = ConnectionCoordinator(
      service: service,
      discovery: BackendDiscoveryService(
        client: createPosHttpClient(),
        defaultApiBaseUrl: service.baseUrl,
      ),
      storage: const SharedPreferencesConnectionProfileStorage(),
      status: connectionStatus,
    );
    // A LAN request failing (server moved / network flapped) triggers a
    // debounced background re-discovery so the target self-heals.
    service.onLocalTargetUnreachable =
        connectionCoordinator.notifyLocalTargetUnreachable;
    clientUpdateService = ClientUpdateService(
      apiBaseUrl: () => service.baseUrl,
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
      trackedStockRepository: trackedStockRepository,
      analyticsEngine: analyticsEngine,
      scanFeedback: ScanFeedbackSounds.instance.play,
    );
    // Tell the API session which drawer this till is working in, so every
    // request carries it and the backend can stamp it onto what it records. A
    // listener rather than a call at each assignment: the session is set from
    // three places across the POS mixins, and one of them being forgotten later
    // is exactly how a field gets silently dropped.
    posViewModel.addListener(() {
      service.describeRegisterSession(
        posViewModel.activeRegisterSession?.id.toString(),
      );
    });
    revalidator = Revalidator(service.serverState);
    serverStateWatcher = ServerStateWatcher(
      fetchState: service.fetchServerState,
      state: service.serverState,
    );
    _registerRevalidationWatchers();
  }

  /// Everything that must refresh itself when the server says its data moved.
  ///
  /// This is the whole list, in one place on purpose: a screen that caches or
  /// holds data and is missing from here is a screen that will show a stale
  /// number until someone restarts the app, and that is far easier to notice
  /// against a list than scattered across twenty view models.
  void _registerRevalidationWatchers() {
    // Permissions are the exception that purges instead of refreshing: a
    // revoked permission must not leave the data it used to authorise sitting
    // readable in a cache. Drop every cached body, then re-resolve who we are
    // so the UI reshapes to whatever this user may now do.
    revalidator.watch(
      label: 'permissions',
      domains: const {ServerStateDomain.permissions},
      debounce: Duration.zero,
      onStale: () async {
        service.purgeCachedResponses();
        catalogRepository.invalidateAll();
        await authViewModel.refreshCurrentUser();
        await _refreshSessionViewModels();
      },
    );
    // The sell screen's own rules live with the sell screen.
    registerPosRevalidation(
      revalidator: revalidator,
      posViewModel: posViewModel,
    );
    // The back-office screens. Each is a view model that loads once and then
    // lives as long as the session, so without this every one of them shows
    // whatever it read the first time it was opened. They are nullable: a
    // screen nobody has visited has nothing to refresh, and stays that way.
    revalidator.watch(
      label: 'contacts',
      domains: const {ServerStateDomain.contacts},
      onStale: () async => _contactManagementViewModel?.loadContacts(),
    );
    revalidator.watch(
      label: 'discounts',
      domains: const {ServerStateDomain.discounts},
      onStale: () async => _discountManagementViewModel?.loadRules(),
    );
    revalidator.watch(
      label: 'employees',
      domains: const {ServerStateDomain.employees},
      onStale: () async => _employeePayrollViewModel?.loadEmployees(),
    );
    revalidator.watch(
      label: 'users',
      domains: const {ServerStateDomain.users},
      onStale: () async => _activityLogViewModel?.loadUsers(),
    );
    revalidator.watch(
      label: 'notifications',
      domains: const {
        ServerStateDomain.notifications,
        ServerStateDomain.notificationsUser,
      },
      onStale: () async => _notificationCenterViewModel?.refresh(),
    );
    // Purchasing reads the same catalog the POS does, and buys at prices the
    // back office edits.
    revalidator.watch(
      label: 'purchasing-catalog',
      domains: const {ServerStateDomain.catalogDefs},
      onStale: () async => _purchaseViewModel?.loadCatalog(),
    );
    revalidator.watch(
      label: 'purchasing-warehouses',
      domains: const {ServerStateDomain.warehouses},
      onStale: () async => _purchaseViewModel?.loadWarehouses(),
    );
    revalidator.watch(
      label: 'fx',
      domains: const {ServerStateDomain.fx},
      onStale: () async => dashboardFxViewModel.load(),
    );
    // The dashboard is a read model over almost everything, and its repository
    // caches a snapshot; anything material moving should re-read it.
    revalidator.watch(
      label: 'dashboard',
      domains: const {
        ServerStateDomain.catalogDefs,
        ServerStateDomain.settings,
        ServerStateDomain.stock,
      },
      // Stock moves on every sale in the shop, so this one waits a beat
      // longer: a dashboard a few seconds behind is fine, a dashboard
      // re-reading itself on every checkout in the building is not.
      debounce: const Duration(seconds: 5),
      onStale: () async {
        // Its repository holds a 45s snapshot; without dropping that first the
        // refresh would be answered from the cache it exists to refresh.
        dashboardRepository.invalidateSnapshots();
        await _dashboardViewModel?.loadDashboard();
      },
    );
  }

  final PosApiService service;

  /// Turns the server's "what changed" counters into screen refreshes.
  late final Revalidator revalidator;

  /// Keeps an idle till hearing about changes it would otherwise miss.
  late final ServerStateWatcher serverStateWatcher;
  late final ClientUpdateService clientUpdateService;
  final bool _enableAutomaticConnection;
  late final AnalyticsRepository analyticsRepository;
  late final AnalyticsEngine analyticsEngine;
  late final AttendanceRepository attendanceRepository;
  late final MigrationRepository migrationRepository;
  late final AuthRepository authRepository;
  late final CatalogRepository catalogRepository;
  late final ContactRepository contactRepository;
  late final DashboardRepository dashboardRepository;
  late final DeviceSettingsRepository deviceSettingsRepository;
  late final ThemeController themeController;
  late final PriceCheckerModeController priceCheckerModeController;
  late final CompanionRepository companionRepository;

  /// The link to a phone lending this till its camera. Created on sign-in
  /// (its endpoints need a session) and torn down on sign-out, because a
  /// companion is scoped to the shift that paired it.
  ///
  /// A notifier rather than a plain field: it appears asynchronously (the till
  /// key is read from storage first), so the widget that publishes it to the
  /// screen tree has to be told when, not guess from the auth transition.
  final ValueNotifier<CompanionBridge?> companionBridgeListenable =
      ValueNotifier(null);

  CompanionBridge? get companionBridge => companionBridgeListenable.value;
  late final BusinessAlertRepository businessAlertRepository;
  late final DiscountRepository discountRepository;
  late final EmployeeRepository employeeRepository;
  late final ExpenseRepository expenseRepository;
  late final FraudRepository fraudRepository;
  late final InventoryRepository inventoryRepository;
  late final OperationsRepository operationsRepository;
  late final RegisterSessionRepository registerSessionRepository;
  late final ReportRepository reportRepository;
  late final SaleRepository saleRepository;
  late final SalesChannelRepository salesChannelRepository;
  late final WarehouseRepository warehouseRepository;
  late final PrepStationRepository prepStationRepository;
  late final ModifierGroupRepository modifierGroupRepository;
  late final ShopSettingsRepository shopSettingsRepository;
  late final DocumentTrailRepository documentTrailRepository;
  late final PrintingRepository printingRepository;
  late final PriceCheckerRepository priceCheckerRepository;
  late final SurveillanceRepository surveillanceRepository;
  late final ScalesRepository scalesRepository;

  /// The dashboard's camera strip. Long-lived so the per-device selection and
  /// the snapshot thumbnails survive navigating away and back, rather than
  /// re-reading storage and re-fetching stills on every visit to the dashboard.
  late final DashboardCamerasViewModel dashboardCamerasViewModel;

  /// The dashboard's exchange-rate band. Long-lived so the rates and their
  /// trend survive navigating away and back: they move a few times a day, and
  /// re-fetching four requests' worth on every visit to the dashboard would be
  /// paying a lot for a number that has not changed.
  late final DashboardFxViewModel dashboardFxViewModel;
  late final AiChatRepository aiChatRepository;
  late final PurchaseRepository purchaseRepository;
  late final PaymentsRepository paymentsRepository;
  late final TreasuryRepository treasuryRepository;
  late final StockCountRepository stockCountRepository;
  late final TrackedStockRepository trackedStockRepository;
  late final TrackedStockViewModel trackedStockViewModel;
  late final SubscriptionRepository subscriptionRepository;
  late final FxRepository fxRepository;
  late final MessagingRepository messagingRepository;
  late final CrmRepository crmRepository;
  late final UserRepository userRepository;
  late final ConnectionCoordinator connectionCoordinator;
  late final ConnectionStatusController connectionStatus;
  late final AuthViewModel authViewModel;
  late final PosViewModel posViewModel;
  DeviceSettingsViewModel? _deviceSettingsViewModel;
  PrintingSettingsViewModel? _printingSettingsViewModel;
  ContactManagementViewModel? _contactManagementViewModel;
  DiscountManagementViewModel? _discountManagementViewModel;
  EmployeePayrollViewModel? _employeePayrollViewModel;
  AttendanceViewModel? _attendanceViewModel;
  MigrationViewModel? _migrationViewModel;
  NotificationCenterViewModel? _notificationCenterViewModel;
  ActivityLogViewModel? _activityLogViewModel;
  ReportsViewModel? _reportsViewModel;
  DashboardViewModel? _dashboardViewModel;
  ConversationsViewModel? _conversationsViewModel;
  CampaignsViewModel? _campaignsViewModel;
  InvoiceListViewModel? _invoiceListViewModel;
  PurchaseViewModel? _purchaseViewModel;
  PurchaseOrderListViewModel? _purchaseOrderListViewModel;
  StockCountSessionsViewModel? _stockCountSessionsViewModel;
  UserSettingsViewModel? _userSettingsViewModel;
  LearningViewModel? _learningViewModel;
  int? _learningViewModelUserId;

  int? _lastAuthenticatedUserId;

  Future<void> start() async {
    // Resolve the saved theme first so the app paints in the right mode without
    // a flash from the default.
    await themeController.load();
    // Resolve kiosk mode before the first frame so a price-checker device boots
    // straight into the kiosk instead of flashing the login screen.
    await priceCheckerModeController.load();
    // A kiosk renders the price checker INSTEAD of the auth gate (see app.dart),
    // so it never signs in — and the ingest endpoint only accepts authenticated
    // callers. Every event such a device records is therefore undeliverable, and
    // in the field one of these produced 5.1M rejected requests, a flat 24/7
    // stream that was 85% of everything the backend served. Collect nothing on a
    // device that structurally cannot deliver it.
    await analyticsEngine.setCollectionEnabled(
      !priceCheckerModeController.enabled,
    );
    priceCheckerModeController.addListener(_handlePriceCheckerModeChanged);
    if (_enableAutomaticConnection) {
      await connectionCoordinator.bootstrap();
    } else {
      // Tests and preview harnesses inject an explicit target — there is no
      // discovery to wait on, so the connection gate is immediately ready.
      connectionStatus.update(ConnectionPhase.connectedLocal);
    }
    final usageModeResult = await deviceSettingsRepository.loadUsageMode();
    final usageMode = switch (usageModeResult) {
      Ok<DeviceUsageMode>(value: final mode) => mode,
      Error<DeviceUsageMode>() => DeviceUsageMode.singleUser,
    };
    _usageMode = usageMode;
    await authViewModel.loadCurrentUser(
      forgetRememberedUser: usageMode == DeviceUsageMode.multiUser,
    );
    // Re-load the current user whenever a target is (re)acquired later — e.g.
    // the user connects manually, or the background sweep finds the moved
    // server — so a login attempt that failed against no target recovers on its
    // own. Registered after the first load so it only handles later transitions.
    _wasConnectionReady = connectionStatus.isReady;
    connectionStatus.addListener(_handleConnectionStatusChanged);
  }

  void _handlePriceCheckerModeChanged() {
    // Entering kiosk mode drops the queue; leaving it starts collecting again.
    unawaited(
      analyticsEngine.setCollectionEnabled(!priceCheckerModeController.enabled),
    );
  }

  DeviceUsageMode _usageMode = DeviceUsageMode.singleUser;
  bool _wasConnectionReady = false;

  void _handleConnectionStatusChanged() {
    final ready = connectionStatus.isReady;
    if (ready &&
        !_wasConnectionReady &&
        authViewModel.status != AuthStatus.authenticated) {
      unawaited(
        authViewModel.loadCurrentUser(
          forgetRememberedUser: _usageMode == DeviceUsageMode.multiUser,
        ),
      );
    }
    _wasConnectionReady = ready;
  }

  /// The learning catalogue's view model.
  ///
  /// Keyed on [userId], not on the [capabilities] object: the authenticated
  /// shell builds a fresh `AuthorizationCapabilities` on every rebuild and the
  /// class has no value equality, so comparing instances would dispose and
  /// replace the view model the mounted screen is still listening to. Keying on
  /// the user still does the job the key is for — the "matches my permissions"
  /// filter must follow whoever is signed in, so the next user gets their own.
  LearningViewModel learningViewModel(
    int userId,
    AuthorizationCapabilities capabilities,
  ) {
    final existing = _learningViewModel;
    if (existing != null && _learningViewModelUserId == userId) {
      return existing;
    }
    existing?.dispose();
    _learningViewModelUserId = userId;
    return _learningViewModel = LearningViewModel(
      capabilities: capabilities,
      userId: userId,
    );
  }

  DeviceSettingsViewModel get deviceSettingsViewModel =>
      _deviceSettingsViewModel ??= DeviceSettingsViewModel(
        deviceSettingsRepository,
        analyticsEngine: analyticsEngine,
      );

  PrintingSettingsViewModel get printingSettingsViewModel =>
      _printingSettingsViewModel ??= PrintingSettingsViewModel(
        printingRepository,
        analyticsEngine: analyticsEngine,
      );

  ConversationsViewModel get conversationsViewModel =>
      _conversationsViewModel ??= ConversationsViewModel(crmRepository);

  CampaignsViewModel get campaignsViewModel =>
      _campaignsViewModel ??= CampaignsViewModel(crmRepository);

  ContactManagementViewModel get contactManagementViewModel =>
      _contactManagementViewModel ??= ContactManagementViewModel(
        contactRepository,
      );

  DiscountManagementViewModel get discountManagementViewModel =>
      _discountManagementViewModel ??= DiscountManagementViewModel(
        discountRepository,
        analyticsEngine: analyticsEngine,
      );

  EmployeePayrollViewModel get employeePayrollViewModel =>
      _employeePayrollViewModel ??= EmployeePayrollViewModel(
        employeeRepository,
        analyticsEngine: analyticsEngine,
      );

  AttendanceViewModel get attendanceViewModel =>
      _attendanceViewModel ??= AttendanceViewModel(
        attendanceRepository,
        analyticsEngine: analyticsEngine,
      );

  MigrationViewModel get migrationViewModel => _migrationViewModel ??=
      MigrationViewModel(migrationRepository, analyticsEngine: analyticsEngine);

  DashboardViewModel get dashboardViewModel =>
      _dashboardViewModel ??= DashboardViewModel(
        dashboardRepository,
        // Read at call time, not at construction: the view model outlives a
        // sign-out, and the next user may have a different entitlement.
        canRequestAiDigest: () {
          final user = authViewModel.currentUser;
          return user != null &&
              AuthorizationCapabilities.forUser(
                user,
              ).allows(AppCapability.useAiAssistant);
        },
      );

  ActivityLogViewModel get activityLogViewModel => _activityLogViewModel ??=
      ActivityLogViewModel(analyticsRepository, userRepository);

  ReportsViewModel get reportsViewModel =>
      _reportsViewModel ??= ReportsViewModel(reportRepository);

  NotificationCenterViewModel get notificationCenterViewModel =>
      _notificationCenterViewModel ??= NotificationCenterViewModel(
        businessAlertRepository,
      );

  InvoiceListViewModel get invoiceListViewModel =>
      _invoiceListViewModel ??= InvoiceListViewModel(
        saleRepository,
        printingRepository,
        shopSettingsRepository,
      );

  PurchaseViewModel get purchaseViewModel =>
      _purchaseViewModel ??= PurchaseViewModel(
        catalogRepository,
        purchaseRepository,
        analyticsEngine: analyticsEngine,
        persistScope: authViewModel.currentUser?.id.toString(),
        fxRepository: fxRepository,
        warehouseRepository: warehouseRepository,
      );

  PurchaseOrderListViewModel get purchaseOrderListViewModel =>
      _purchaseOrderListViewModel ??= PurchaseOrderListViewModel(
        purchaseRepository,
        printingRepository,
        shopSettingsRepository,
      );

  StockCountSessionsViewModel get stockCountSessionsViewModel =>
      _stockCountSessionsViewModel ??= StockCountSessionsViewModel(
        stockCountRepository,
      );

  UserSettingsViewModel get userSettingsViewModel =>
      _userSettingsViewModel ??= UserSettingsViewModel(
        authRepository,
        employeeRepository,
        analyticsEngine: analyticsEngine,
      );

  void handleAuthChanged() {
    final currentUser = authViewModel.currentUser;
    if (authViewModel.status == AuthStatus.authenticated &&
        currentUser != null &&
        _lastAuthenticatedUserId != currentUser.id) {
      _lastAuthenticatedUserId = currentUser.id;
      analyticsEngine.setCurrentUser(currentUser.id);
      // Telemetry queued on the login screen was held back (the ingest
      // endpoint rejects anonymous callers); now that we're signed in, ship
      // that backlog instead of waiting for the next flush tick.
      unawaited(analyticsEngine.flush());
      unawaited(
        analyticsEngine.trackUsage(
          AnalyticsEventName.authSessionStarted,
          attributes: {'role': currentUser.role.toJson()},
        ),
      );
      unawaited(_startCompanionBridge());
      // Start listening for other devices' edits only once there is a session
      // to make the request with; an anonymous poll would just 401 forever.
      serverStateWatcher.start();
      posViewModel.loadCurrentRegisterSession();
      posViewModel.loadCheckoutSettings();
      unawaited(posViewModel.restorePersistedSessions('${currentUser.id}'));
      unawaited(notificationCenterViewModel.loadAlerts());
      if (_enableAutomaticConnection) {
        unawaited(connectionCoordinator.pairAuthenticatedDevice());
      }
      // Feature view models that survived the last session still need a
      // refresh (a different user's permissions can reshape their lists),
      // but sequentially in the background — the old parallel fan-out landed
      // ~11 simultaneous requests at the exact moment the POS is loading.
      unawaited(_refreshSessionViewModels());
    }

    if (authViewModel.status == AuthStatus.unauthenticated) {
      _lastAuthenticatedUserId = null;
      analyticsEngine.setCurrentUser(null);
      serverStateWatcher.stop();
      _stopCompanionBridge();
      _disposeSessionViewModels();
    }
  }

  Future<void> _startCompanionBridge() async {
    if (companionBridgeListenable.value != null) return;
    // The till key is this install's own stable id — the same one the
    // connection profile keeps — so a phone stays paired across restarts,
    // updates and shift changes rather than to whoever happens to be signed in.
    final tillKey = await const SharedPreferencesConnectionProfileStorage()
        .loadOrCreateDeviceId();
    if (authViewModel.status != AuthStatus.authenticated) return;
    final bridge = CompanionBridge(
      repository: companionRepository,
      tillKey: tillKey,
    );
    companionBridgeListenable.value = bridge;
    await bridge.start();
  }

  void _stopCompanionBridge() {
    final bridge = companionBridgeListenable.value;
    companionBridgeListenable.value = null;
    bridge?.dispose();
  }

  Future<void> _refreshSessionViewModels() async {
    final steps = <Future<void>? Function()>[
      () => _dashboardViewModel?.loadDashboard(),
      () => _invoiceListViewModel?.loadInvoices(),
      () => _purchaseViewModel?.loadCatalog(),
      () => _purchaseOrderListViewModel?.loadOrders(),
      () => _contactManagementViewModel?.loadContacts(),
      () => _discountManagementViewModel?.loadRules(),
      () => _employeePayrollViewModel?.loadEmployees(),
      () => _employeePayrollViewModel?.loadPayrollRuns(),
      () => _employeePayrollViewModel?.loadLoans(),
      () => _activityLogViewModel?.loadEvents(),
      () => _activityLogViewModel?.loadUsers(),
      // The catalogue carries the period-lock state, so a refresh keeps the
      // reports screen honest about whether the books are closed.
      () => _reportsViewModel?.load(),
    ];
    for (final step in steps) {
      try {
        await (step() ?? Future<void>.value());
      } catch (_) {
        // Each view model surfaces its own error state; one failed refresh
        // must not abort the rest of the chain.
      }
    }
  }

  void dispose() {
    serverStateWatcher.dispose();
    revalidator.dispose();
    connectionStatus.removeListener(_handleConnectionStatusChanged);
    connectionStatus.dispose();
    connectionCoordinator.dispose();
    analyticsEngine.dispose();
    themeController.dispose();
    _stopCompanionBridge();
    companionBridgeListenable.dispose();
    priceCheckerModeController.removeListener(_handlePriceCheckerModeChanged);
    priceCheckerModeController.dispose();
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
    _employeePayrollViewModel?.dispose();
    _employeePayrollViewModel = null;
    _notificationCenterViewModel?.dispose();
    _notificationCenterViewModel = null;
    _activityLogViewModel?.dispose();
    _activityLogViewModel = null;
    _dashboardViewModel?.dispose();
    _dashboardViewModel = null;
    _invoiceListViewModel?.dispose();
    _invoiceListViewModel = null;
    _purchaseViewModel?.dispose();
    _purchaseViewModel = null;
    _purchaseOrderListViewModel?.dispose();
    _purchaseOrderListViewModel = null;
    _stockCountSessionsViewModel?.dispose();
    _stockCountSessionsViewModel = null;
    _userSettingsViewModel?.dispose();
    _userSettingsViewModel = null;
    _learningViewModel?.dispose();
    _learningViewModel = null;
    _learningViewModelUserId = null;
  }
}
