import 'data/repositories/auth_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/contact_repository.dart';
import 'data/repositories/inventory_repository.dart';
import 'data/repositories/printing_repository.dart';
import 'data/repositories/purchase_repository.dart';
import 'data/repositories/register_session_repository.dart';
import 'data/repositories/sale_repository.dart';
import 'data/repositories/shop_settings_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/services/pos_api_service.dart';
import 'features/auth/view_models/auth_view_model.dart';
import 'features/contacts/view_models/contact_management_view_model.dart';
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
    inventoryRepository = InventoryRepository(service);
    registerSessionRepository = RegisterSessionRepository(service);
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
    printingSettingsViewModel = PrintingSettingsViewModel(printingRepository);
    contactManagementViewModel = ContactManagementViewModel(contactRepository);
    purchaseViewModel = PurchaseViewModel(
      catalogRepository,
      purchaseRepository,
    );
    purchaseOrderListViewModel = PurchaseOrderListViewModel(purchaseRepository);
  }

  final PosApiService service;
  late final AuthRepository authRepository;
  late final CatalogRepository catalogRepository;
  late final ContactRepository contactRepository;
  late final InventoryRepository inventoryRepository;
  late final RegisterSessionRepository registerSessionRepository;
  late final SaleRepository saleRepository;
  late final ShopSettingsRepository shopSettingsRepository;
  late final PrintingRepository printingRepository;
  late final PurchaseRepository purchaseRepository;
  late final UserRepository userRepository;
  late final AuthViewModel authViewModel;
  late final PosViewModel posViewModel;
  late final PrintingSettingsViewModel printingSettingsViewModel;
  late final ContactManagementViewModel contactManagementViewModel;
  late final PurchaseViewModel purchaseViewModel;
  late final PurchaseOrderListViewModel purchaseOrderListViewModel;

  int? _lastAuthenticatedUserId;

  void handleAuthChanged() {
    final currentUser = authViewModel.currentUser;
    if (authViewModel.status == AuthStatus.authenticated &&
        currentUser != null &&
        _lastAuthenticatedUserId != currentUser.id) {
      _lastAuthenticatedUserId = currentUser.id;
      posViewModel.loadCurrentRegisterSession();
      posViewModel.loadCheckoutSettings();
      purchaseViewModel.loadCatalog();
      purchaseOrderListViewModel.loadOrders();
      contactManagementViewModel.loadContacts();
    }

    if (authViewModel.status == AuthStatus.unauthenticated) {
      _lastAuthenticatedUserId = null;
    }
  }

  void dispose() {
    authViewModel.dispose();
    posViewModel.dispose();
    printingSettingsViewModel.dispose();
    contactManagementViewModel.dispose();
    purchaseViewModel.dispose();
    purchaseOrderListViewModel.dispose();
  }
}
