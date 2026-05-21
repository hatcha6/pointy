import 'data/repositories/auth_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/contact_repository.dart';
import 'data/repositories/dashboard_repository.dart';
import 'data/repositories/discount_repository.dart';
import 'data/repositories/inventory_repository.dart';
import 'data/repositories/printing_repository.dart';
import 'data/repositories/purchase_repository.dart';
import 'data/repositories/register_session_repository.dart';
import 'data/repositories/report_repository.dart';
import 'data/repositories/sale_repository.dart';
import 'data/repositories/shop_settings_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/services/pos_api_service.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/contacts/view_models/contact_management_view_model.dart';
import 'features/dashboard/view_models/dashboard_view_model.dart';
import 'features/discounts/view_models/discount_management_view_model.dart';
import 'features/pos/view_models/pos_view_model.dart';
import 'features/printing/view_models/printing_settings_view_model.dart';
import 'features/purchasing/view_models/purchase_order_list_view_model.dart';
import 'features/purchasing/view_models/purchase_view_model.dart';

class PointyAppDependencies {
  PointyAppDependencies({PosApiService? apiService})
    : service = apiService ?? PosApiService() {
    authRepository = AuthRepository(service);
    catalogRepository = CatalogRepository(service);
    contactRepository = ContactRepository(service);
    dashboardRepository = DashboardRepository(service);
    discountRepository = DiscountRepository(service);
    inventoryRepository = InventoryRepository(service);
    registerSessionRepository = RegisterSessionRepository(service);
    reportRepository = ReportRepository(service);
    saleRepository = SaleRepository(service);
    shopSettingsRepository = ShopSettingsRepository(service);
    printingRepository = PrintingRepository(service);
    purchaseRepository = PurchaseRepository(service);
    userRepository = UserRepository(service);
    authViewModel = AuthViewModel(authRepository);
    posViewModel = PosViewModel(
      catalogRepository,
      registerSessionRepository,
      saleRepository,
      shopSettingsRepository,
      printingRepository,
    );
  }

  final PosApiService service;
  late final AuthRepository authRepository;
  late final CatalogRepository catalogRepository;
  late final ContactRepository contactRepository;
  late final DashboardRepository dashboardRepository;
  late final DiscountRepository discountRepository;
  late final InventoryRepository inventoryRepository;
  late final RegisterSessionRepository registerSessionRepository;
  late final ReportRepository reportRepository;
  late final SaleRepository saleRepository;
  late final ShopSettingsRepository shopSettingsRepository;
  late final PrintingRepository printingRepository;
  late final PurchaseRepository purchaseRepository;
  late final UserRepository userRepository;
  late final AuthViewModel authViewModel;
  late final PosViewModel posViewModel;
  PrintingSettingsViewModel? _printingSettingsViewModel;
  ContactManagementViewModel? _contactManagementViewModel;
  DiscountManagementViewModel? _discountManagementViewModel;
  DashboardViewModel? _dashboardViewModel;
  PurchaseViewModel? _purchaseViewModel;
  PurchaseOrderListViewModel? _purchaseOrderListViewModel;

  int? _lastAuthenticatedUserId;

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

  PurchaseViewModel get purchaseViewModel => _purchaseViewModel ??=
      PurchaseViewModel(catalogRepository, purchaseRepository);

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
      posViewModel.loadCurrentRegisterSession();
      posViewModel.loadCheckoutSettings();
      _dashboardViewModel?.loadDashboard();
      _purchaseViewModel?.loadCatalog();
      _purchaseOrderListViewModel?.loadOrders();
      _contactManagementViewModel?.loadContacts();
      _discountManagementViewModel?.loadRules();
    }

    if (authViewModel.status == AuthStatus.unauthenticated) {
      _lastAuthenticatedUserId = null;
      _disposeSessionViewModels();
    }
  }

  void dispose() {
    authViewModel.dispose();
    posViewModel.dispose();
    _disposeSessionViewModels();
  }

  void _disposeSessionViewModels() {
    _printingSettingsViewModel?.dispose();
    _printingSettingsViewModel = null;
    _contactManagementViewModel?.dispose();
    _contactManagementViewModel = null;
    _discountManagementViewModel?.dispose();
    _discountManagementViewModel = null;
    _dashboardViewModel?.dispose();
    _dashboardViewModel = null;
    _purchaseViewModel?.dispose();
    _purchaseViewModel = null;
    _purchaseOrderListViewModel?.dispose();
    _purchaseOrderListViewModel = null;
  }
}
