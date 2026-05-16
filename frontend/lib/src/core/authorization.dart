import '../data/models/pos_user.dart';

typedef AuthorizedAction = void Function();
typedef AuthorizedAsyncAction = Future<void> Function();

enum AppCapability {
  accessPos,
  checkoutSale,
  startRegisterSession,
  resumeRegisterSession,
  closeRegisterSession,
  viewCatalogManagement,
  createProduct,
  viewRegisterSessions,
  viewRegisterSessionOrders,
  manageUsers,
  manageShopSettings,
}

class AuthorizationCapabilities {
  const AuthorizationCapabilities._(this._capabilities);

  factory AuthorizationCapabilities.forUser(PosUser user) {
    if (user.role.isManager) {
      return AuthorizationCapabilities._(Set.of(AppCapability.values));
    }

    final capabilities = <AppCapability>{
      AppCapability.accessPos,
      AppCapability.checkoutSale,
      AppCapability.startRegisterSession,
      AppCapability.resumeRegisterSession,
      AppCapability.closeRegisterSession,
    };

    if (user.permissions.isNotEmpty) {
      if (_hasAny(user, const ['add_product', 'catalog.add_product'])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.createProduct);
      }
      if (_hasAny(user, const [
        'change_product',
        'delete_product',
        'catalog.change_product',
        'catalog.delete_product',
      ])) {
        capabilities.add(AppCapability.viewCatalogManagement);
      }
      if (_hasAny(user, const [
        'view_registersession',
        'sales.view_registersession',
      ])) {
        capabilities.add(AppCapability.viewRegisterSessions);
      }
      if (_hasAny(user, const ['view_order', 'sales.view_order'])) {
        capabilities
          ..add(AppCapability.viewRegisterSessions)
          ..add(AppCapability.viewRegisterSessionOrders);
      }
      if (_hasAny(user, const ['add_order', 'sales.add_order'])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.checkoutSale);
      }
      if (_hasAny(user, const [
        'add_registersession',
        'sales.add_registersession',
      ])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.startRegisterSession)
          ..add(AppCapability.resumeRegisterSession);
      }
      if (_hasAny(user, const [
        'change_registersession',
        'sales.change_registersession',
      ])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.closeRegisterSession);
      }
      if (_hasAny(user, const [
        'add_user',
        'change_user',
        'delete_user',
        'view_user',
        'auth.add_user',
        'auth.change_user',
        'auth.delete_user',
        'auth.view_user',
      ])) {
        capabilities.add(AppCapability.manageUsers);
      }
      if (_hasAny(user, const [
        'change_shopsettings',
        'view_shopsettings',
        'core.change_shopsettings',
        'core.view_shopsettings',
      ])) {
        capabilities.add(AppCapability.manageShopSettings);
      }
    }

    return AuthorizationCapabilities._(capabilities);
  }

  final Set<AppCapability> _capabilities;

  bool allows(AppCapability capability) => _capabilities.contains(capability);

  bool get canAccessPos => allows(AppCapability.accessPos);
  bool get canCheckoutSale => allows(AppCapability.checkoutSale);
  bool get canStartRegisterSession =>
      allows(AppCapability.startRegisterSession);
  bool get canResumeRegisterSession =>
      allows(AppCapability.resumeRegisterSession);
  bool get canCloseRegisterSession =>
      allows(AppCapability.closeRegisterSession);
  bool get canViewCatalogManagement =>
      allows(AppCapability.viewCatalogManagement);
  bool get canCreateProduct => allows(AppCapability.createProduct);
  bool get canViewRegisterSessions =>
      allows(AppCapability.viewRegisterSessions);
  bool get canViewRegisterSessionOrders =>
      allows(AppCapability.viewRegisterSessionOrders);
  bool get canManageUsers => allows(AppCapability.manageUsers);
  bool get canManageShopSettings => allows(AppCapability.manageShopSettings);

  AuthorizedAction? actionFor(
    AppCapability capability,
    AuthorizedAction action,
  ) {
    return allows(capability) ? action : null;
  }

  AuthorizedAsyncAction? asyncActionFor(
    AppCapability capability,
    AuthorizedAsyncAction action,
  ) {
    return allows(capability) ? action : null;
  }

  static bool _hasAny(PosUser user, Iterable<String> permissions) {
    return permissions.any(user.permissions.contains);
  }
}
