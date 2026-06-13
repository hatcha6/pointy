import '../data/models/pos_user.dart';

typedef AuthorizedAction = void Function();
typedef AuthorizedAsyncAction = Future<void> Function();

enum AppCapability {
  viewDashboard,
  viewSalesDashboard,
  viewPaymentDashboard,
  viewInventoryDashboard,
  viewPurchasingDashboard,
  viewCustomerDashboard,
  viewDiscountDashboard,
  viewPrintingDashboard,
  viewReports,
  viewActivityLog,
  viewFraudFindings,
  manageFraudFindings,
  viewEmployees,
  manageEmployees,
  manageOwnAccount,
  viewEmployeeLoans,
  manageEmployeeLoans,
  viewPayroll,
  managePayroll,
  accessPos,
  viewInvoices,
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
  manageCategories,
  createProduct,
  changeProduct,
  createProductVariant,
  changeProductVariant,
  viewRegisterSessions,
  viewRegisterSessionOrders,
  manageDeviceSettings,
  manageUsers,
  manageShopSettings,
  manageSalesChannels,
  viewAttendance,
  manageAttendance,
  viewOperations,
  createJobs,
  manageJobMaterials,
  manageWorkflows,
  manageRecipes,
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

    // Deliberately no dashboard capabilities here: revenue aggregates would
    // tell a cashier exactly how much cash the drawer should hold, defeating
    // the blind close. Dashboards are granted below from explicit reporting
    // permissions instead.
    final capabilities = <AppCapability>{
      AppCapability.accessPos,
      AppCapability.manageOwnAccount,
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
        'add_productvariant',
        'catalog.add_productvariant',
      ])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.createProductVariant);
      }
      if (_hasAny(user, const [
        'add_productcategory',
        'change_productcategory',
        'delete_productcategory',
        'catalog.add_productcategory',
        'catalog.change_productcategory',
        'catalog.delete_productcategory',
      ])) {
        capabilities.add(AppCapability.manageCategories);
      }
      if (_hasAny(user, const [
        'change_product',
        'delete_product',
        'catalog.change_product',
        'catalog.delete_product',
      ])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.changeProduct);
      }
      if (_hasAny(user, const [
        'change_productvariant',
        'delete_productvariant',
        'catalog.change_productvariant',
        'catalog.delete_productvariant',
      ])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.changeProductVariant);
      }
      if (_hasAny(user, const [
        'view_stockitem',
        'view_stockmovement',
        'inventory.view_stockitem',
        'inventory.view_stockmovement',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewInventoryDashboard)
          ..add(AppCapability.viewStock);
      }
      if (_hasAny(user, const [
        'add_stockmovement',
        'inventory.add_stockmovement',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewInventoryDashboard)
          ..add(AppCapability.viewStock)
          ..add(AppCapability.createStockMovement);
      }
      if (_hasAny(user, const [
        'view_purchaseorder',
        'change_purchaseorder',
        'purchasing.view_purchaseorder',
        'purchasing.change_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewPurchasingDashboard)
          ..add(AppCapability.accessPurchasing);
      }
      if (_hasAny(user, const [
        'add_purchaseorder',
        'purchasing.add_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewPurchasingDashboard)
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
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewCustomerDashboard)
          ..add(AppCapability.manageContacts);
      }
      if (_hasAny(user, const [
        'view_registersession',
        'sales.view_registersession',
      ])) {
        capabilities.add(AppCapability.viewRegisterSessions);
      }
      if (_hasAny(user, const ['view_order', 'sales.view_order'])) {
        capabilities
          ..add(AppCapability.viewInvoices)
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
      // Revenue dashboards are reserved for reporting roles: holding the POS
      // permissions (view_payment, view_order) alone must not reveal shop-wide
      // cash totals to the person counting the drawer.
      if (_hasAny(user, const ['view_reportrun', 'reports.view_reportrun'])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewSalesDashboard);
        if (_hasAny(user, const ['view_payment', 'payments.view_payment'])) {
          capabilities.add(AppCapability.viewPaymentDashboard);
        }
        if (_hasAny(user, const ['view_printjob', 'printing.view_printjob'])) {
          capabilities.add(AppCapability.viewPrintingDashboard);
        }
      }
      if (_hasAny(user, const ['view_employee', 'employees.view_employee'])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees);
      }
      if (_hasAny(user, const [
        'view_employeeloan',
        'employees.view_employeeloan',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.viewEmployeeLoans);
      }
      if (_hasAny(user, const [
        'change_employeeloan',
        'approve_employeeloan',
        'reject_employeeloan',
        'employees.change_employeeloan',
        'employees.approve_employeeloan',
        'employees.reject_employeeloan',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.viewEmployeeLoans)
          ..add(AppCapability.manageEmployeeLoans);
      }
      if (_hasAny(user, const [
        'add_employee',
        'change_employee',
        'delete_employee',
        'add_compensationplan',
        'change_compensationplan',
        'employees.add_employee',
        'employees.change_employee',
        'employees.delete_employee',
        'employees.add_compensationplan',
        'employees.change_compensationplan',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.manageEmployees);
      }
      if (_hasAny(user, const [
        'view_payrollrun',
        'employees.view_payrollrun',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewPayroll);
      }
      if (_hasAny(user, const [
        'add_payrollrun',
        'change_payrollrun',
        'delete_payrollrun',
        'approve_payrollrun',
        'mark_payrollrun_paid',
        'void_payrollrun',
        'employees.add_payrollrun',
        'employees.change_payrollrun',
        'employees.delete_payrollrun',
        'employees.approve_payrollrun',
        'employees.mark_payrollrun_paid',
        'employees.void_payrollrun',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.viewPayroll)
          ..add(AppCapability.managePayroll);
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
        'change_saleschannel',
        'channels.change_saleschannel',
      ])) {
        capabilities.add(AppCapability.manageSalesChannels);
      }
      if (_hasAny(user, const [
        'view_attendanceday',
        'attendance.view_attendanceday',
      ])) {
        capabilities.add(AppCapability.viewAttendance);
      }
      if (_hasAny(user, const [
        'change_biotimeconnection',
        'attendance.change_biotimeconnection',
      ])) {
        capabilities
          ..add(AppCapability.viewAttendance)
          ..add(AppCapability.manageAttendance);
      }
      if (_hasAny(user, const ['view_job', 'operations.view_job'])) {
        capabilities.add(AppCapability.viewOperations);
      }
      if (_hasAny(user, const ['add_job', 'operations.add_job'])) {
        capabilities
          ..add(AppCapability.viewOperations)
          ..add(AppCapability.createJobs);
      }
      if (_hasAny(user, const [
        'add_jobmaterial',
        'operations.add_jobmaterial',
      ])) {
        capabilities.add(AppCapability.manageJobMaterials);
      }
      if (_hasAny(user, const [
        'change_workflowtemplate',
        'operations.change_workflowtemplate',
      ])) {
        capabilities.add(AppCapability.manageWorkflows);
      }
      if (_hasAny(user, const [
        'change_billofmaterials',
        'catalog.change_billofmaterials',
      ])) {
        capabilities.add(AppCapability.manageRecipes);
      }
      if (_hasAny(user, const [
        'view_discountrule',
        'discounts.view_discountrule',
        'view_reportrun',
        'reports.view_reportrun',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewDiscountDashboard)
          ..add(AppCapability.viewDiscountRules);
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
      if (_hasAny(user, const [
        'view_analyticsevent',
        'analytics.view_analyticsevent',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewActivityLog);
      }
      if (_hasAny(user, const [
        'view_fraudfinding',
        'fraud.view_fraudfinding',
      ])) {
        capabilities.add(AppCapability.viewFraudFindings);
      }
      if (_hasAny(user, const [
        'change_fraudfinding',
        'fraud.change_fraudfinding',
      ])) {
        capabilities
          ..add(AppCapability.viewFraudFindings)
          ..add(AppCapability.manageFraudFindings);
      }
      if (_hasAny(user, const [
        'view_reportrun',
        'reports.view_reportrun',
        'view_order',
        'sales.view_order',
        'view_registersession',
        'sales.view_registersession',
        'view_payment',
        'payments.view_payment',
        'view_stockitem',
        'inventory.view_stockitem',
        'view_stockmovement',
        'inventory.view_stockmovement',
        'view_purchaseorder',
        'purchasing.view_purchaseorder',
        'view_customer',
        'customers.view_customer',
        'view_supplier',
        'purchasing.view_supplier',
        'view_discountrule',
        'discounts.view_discountrule',
      ])) {
        capabilities.add(AppCapability.viewReports);
      }
    }

    return AuthorizationCapabilities._(capabilities);
  }

  final Set<AppCapability> _capabilities;

  bool allows(AppCapability capability) => _capabilities.contains(capability);

  bool get canViewDashboard => allows(AppCapability.viewDashboard);
  bool get canViewSalesDashboard => allows(AppCapability.viewSalesDashboard);
  bool get canViewPaymentDashboard =>
      allows(AppCapability.viewPaymentDashboard);
  bool get canViewInventoryDashboard =>
      allows(AppCapability.viewInventoryDashboard);
  bool get canViewPurchasingDashboard =>
      allows(AppCapability.viewPurchasingDashboard);
  bool get canViewCustomerDashboard =>
      allows(AppCapability.viewCustomerDashboard);
  bool get canViewDiscountDashboard =>
      allows(AppCapability.viewDiscountDashboard);
  bool get canViewPrintingDashboard =>
      allows(AppCapability.viewPrintingDashboard);
  bool get canViewReports => allows(AppCapability.viewReports);
  bool get canViewActivityLog => allows(AppCapability.viewActivityLog);
  bool get canViewFraudFindings => allows(AppCapability.viewFraudFindings);
  bool get canManageFraudFindings => allows(AppCapability.manageFraudFindings);
  bool get canViewEmployees => allows(AppCapability.viewEmployees);
  bool get canManageEmployees => allows(AppCapability.manageEmployees);
  bool get canManageOwnAccount => allows(AppCapability.manageOwnAccount);
  bool get canViewEmployeeLoans => allows(AppCapability.viewEmployeeLoans);
  bool get canManageEmployeeLoans => allows(AppCapability.manageEmployeeLoans);
  bool get canViewPayroll => allows(AppCapability.viewPayroll);
  bool get canManagePayroll => allows(AppCapability.managePayroll);
  bool get canViewAttendance => allows(AppCapability.viewAttendance);
  bool get canManageAttendance => allows(AppCapability.manageAttendance);
  bool get canAccessPos => allows(AppCapability.accessPos);
  bool get canViewInvoices => allows(AppCapability.viewInvoices);
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
  bool get canManageCategories => allows(AppCapability.manageCategories);
  bool get canCreateProduct => allows(AppCapability.createProduct);
  bool get canChangeProduct => allows(AppCapability.changeProduct);
  bool get canCreateProductVariant =>
      allows(AppCapability.createProductVariant);
  bool get canChangeProductVariant =>
      allows(AppCapability.changeProductVariant);
  bool get canViewRegisterSessions =>
      allows(AppCapability.viewRegisterSessions);
  bool get canViewRegisterSessionOrders =>
      allows(AppCapability.viewRegisterSessionOrders);
  bool get canManageDeviceSettings =>
      allows(AppCapability.manageDeviceSettings);
  bool get canManageUsers => allows(AppCapability.manageUsers);
  bool get canManageShopSettings => allows(AppCapability.manageShopSettings);
  bool get canManageSalesChannels =>
      allows(AppCapability.manageSalesChannels);
  bool get canViewOperations => allows(AppCapability.viewOperations);
  bool get canCreateJobs => allows(AppCapability.createJobs);
  bool get canManageJobMaterials => allows(AppCapability.manageJobMaterials);
  bool get canManageWorkflows => allows(AppCapability.manageWorkflows);
  bool get canManageRecipes => allows(AppCapability.manageRecipes);
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
