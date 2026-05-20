import '../data/models/pos_user.dart';

typedef AuthorizedAction = void Function();
typedef AuthorizedAsyncAction = Future<void> Function();

enum AppCapability {
  accessPos,
  accessPurchasing,
  createPurchaseOrder,
  editDraftPurchaseOrder,
  receivePurchaseOrder,
  adjustPurchaseOrder,
  cancelPurchaseOrder,
  deletePurchaseOrder,
  manageContacts,
  checkoutSale,
  startRegisterSession,
  resumeRegisterSession,
  closeRegisterSession,
  createRegisterCashMovement,
  viewCatalogManagement,
  createProduct,
  viewRegisterSessions,
  viewRegisterSessionOrders,
  manageDeviceSettings,
  manageUsers,
  manageShopSettings,
  viewDiscountRules,
  createDiscountRule,
  changeDiscountRule,
  deleteDiscountRule,
  viewStock,
  createStockMovement,
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
      AppCapability.createRegisterCashMovement,
      AppCapability.manageDeviceSettings,
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
        'view_stockitem',
        'view_stockmovement',
        'inventory.view_stockitem',
        'inventory.view_stockmovement',
      ])) {
        capabilities.add(AppCapability.viewStock);
      }
      if (_hasAny(user, const [
        'add_stockmovement',
        'inventory.add_stockmovement',
      ])) {
        capabilities
          ..add(AppCapability.viewStock)
          ..add(AppCapability.createStockMovement);
      }
      if (_hasAny(user, const [
        'view_purchaseorder',
        'change_purchaseorder',
        'purchasing.view_purchaseorder',
        'purchasing.change_purchaseorder',
      ])) {
        capabilities.add(AppCapability.accessPurchasing);
      }
      if (_hasAny(user, const [
        'add_purchaseorder',
        'purchasing.add_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.createPurchaseOrder);
      }
      if (_hasAny(user, const [
        'edit_draft_purchaseorder',
        'purchasing.edit_draft_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.editDraftPurchaseOrder);
      }
      if (_hasAny(user, const [
        'receive_purchaseorder',
        'purchasing.receive_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.receivePurchaseOrder);
      }
      if (_hasAny(user, const [
        'adjust_received_purchaseorder',
        'purchasing.adjust_received_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.adjustPurchaseOrder);
      }
      if (_hasAny(user, const [
        'cancel_purchaseorder',
        'purchasing.cancel_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.cancelPurchaseOrder);
      }
      if (_hasAny(user, const [
        'delete_purchaseorder',
        'purchasing.delete_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.deletePurchaseOrder);
      }
      if (_hasAny(user, const [
        'view_customer',
        'add_customer',
        'change_customer',
        'delete_customer',
        'customers.view_customer',
        'customers.add_customer',
        'customers.change_customer',
        'customers.delete_customer',
        'view_supplier',
        'add_supplier',
        'change_supplier',
        'delete_supplier',
        'purchasing.view_supplier',
        'purchasing.add_supplier',
        'purchasing.change_supplier',
        'purchasing.delete_supplier',
      ])) {
        capabilities.add(AppCapability.manageContacts);
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
        'add_registercashmovement',
        'sales.add_registercashmovement',
      ])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.createRegisterCashMovement);
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
        'core.change_shopsettings',
      ])) {
        capabilities.add(AppCapability.manageShopSettings);
      }
      if (_hasAny(user, const [
        'view_discountrule',
        'discounts.view_discountrule',
      ])) {
        capabilities.add(AppCapability.viewDiscountRules);
      }
      if (_hasAny(user, const [
        'add_discountrule',
        'discounts.add_discountrule',
      ])) {
        capabilities
          ..add(AppCapability.viewDiscountRules)
          ..add(AppCapability.createDiscountRule);
      }
      if (_hasAny(user, const [
        'change_discountrule',
        'discounts.change_discountrule',
      ])) {
        capabilities
          ..add(AppCapability.viewDiscountRules)
          ..add(AppCapability.changeDiscountRule);
      }
      if (_hasAny(user, const [
        'delete_discountrule',
        'discounts.delete_discountrule',
      ])) {
        capabilities
          ..add(AppCapability.viewDiscountRules)
          ..add(AppCapability.deleteDiscountRule);
      }
    }

    return AuthorizationCapabilities._(capabilities);
  }

  final Set<AppCapability> _capabilities;

  bool allows(AppCapability capability) => _capabilities.contains(capability);

  bool get canAccessPos => allows(AppCapability.accessPos);
  bool get canAccessPurchasing => allows(AppCapability.accessPurchasing);
  bool get canCreatePurchaseOrder => allows(AppCapability.createPurchaseOrder);
  bool get canEditDraftPurchaseOrder =>
      allows(AppCapability.editDraftPurchaseOrder);
  bool get canReceivePurchaseOrder =>
      allows(AppCapability.receivePurchaseOrder);
  bool get canAdjustPurchaseOrder => allows(AppCapability.adjustPurchaseOrder);
  bool get canCancelPurchaseOrder => allows(AppCapability.cancelPurchaseOrder);
  bool get canDeletePurchaseOrder => allows(AppCapability.deletePurchaseOrder);
  bool get canManageContacts => allows(AppCapability.manageContacts);
  bool get canCheckoutSale => allows(AppCapability.checkoutSale);
  bool get canStartRegisterSession =>
      allows(AppCapability.startRegisterSession);
  bool get canResumeRegisterSession =>
      allows(AppCapability.resumeRegisterSession);
  bool get canCloseRegisterSession =>
      allows(AppCapability.closeRegisterSession);
  bool get canCreateRegisterCashMovement =>
      allows(AppCapability.createRegisterCashMovement);
  bool get canViewCatalogManagement =>
      allows(AppCapability.viewCatalogManagement);
  bool get canCreateProduct => allows(AppCapability.createProduct);
  bool get canViewRegisterSessions =>
      allows(AppCapability.viewRegisterSessions);
  bool get canViewRegisterSessionOrders =>
      allows(AppCapability.viewRegisterSessionOrders);
  bool get canManageDeviceSettings =>
      allows(AppCapability.manageDeviceSettings);
  bool get canManageUsers => allows(AppCapability.manageUsers);
  bool get canManageShopSettings => allows(AppCapability.manageShopSettings);
  bool get canViewDiscountRules => allows(AppCapability.viewDiscountRules);
  bool get canCreateDiscountRule => allows(AppCapability.createDiscountRule);
  bool get canChangeDiscountRule => allows(AppCapability.changeDiscountRule);
  bool get canDeleteDiscountRule => allows(AppCapability.deleteDiscountRule);
  bool get canViewStock => allows(AppCapability.viewStock);
  bool get canCreateStockMovement => allows(AppCapability.createStockMovement);

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
