import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

// Role permission bundles as backend/apps/core/roles.py defines them, for tests
// that need to know what a real role can and cannot reach. A snapshot, not a
// source of truth: when a role changes there, change it here too.

/// مسؤول المشتريات: the whole purchase-order lifecycle, and reading what the
/// suppliers were paid — but not paying them.
const purchasingAgentPermissions = <String>{
  'integrations.record_integration_topup',
  'core.view_shopsettings',
  'catalog.view_product',
  'catalog.view_productcategory',
  'catalog.view_unitofmeasure',
  'catalog.view_scalebarcoderule',
  'purchasing.view_supplier',
  'purchasing.add_supplier',
  'purchasing.change_supplier',
  'purchasing.view_purchaseorder',
  'purchasing.add_purchaseorder',
  'purchasing.edit_draft_purchaseorder',
  'purchasing.receive_purchaseorder',
  'purchasing.adjust_received_purchaseorder',
  'purchasing.cancel_purchaseorder',
  'purchasing.add_pos_cash_purchase',
  'purchasing.view_supplierpayment',
  'inventory.view_stockunit',
  'inventory.add_stockunit',
  'inventory.view_stockbatch',
  'inventory.manage_batches',
  'inventory.view_stockitem',
  'inventory.view_warehouse',
  'inventory.view_stocktransfer',
  'sales.view_registerprofile',
  'inventory.view_stockmovement',
  'analytics.add_analyticsevent',
};

/// مدقق: read-only across the operational and financial picture.
const auditorPermissions = <String>{
  'reports.view_reportrun',
  'analytics.view_analyticsevent',
  'core.view_shopsettings',
  'sales.view_order',
  'sales.view_registersession',
  'sales.view_registercashmovement',
  'payments.view_payment',
  'inventory.view_stockitem',
  'inventory.view_warehouse',
  'inventory.view_stocktransfer',
  'sales.view_registerprofile',
  'inventory.view_stockmovement',
  'inventory.view_stockcount',
  'purchasing.view_purchaseorder',
  'purchasing.view_supplier',
  'purchasing.view_supplierpayment',
  'customers.view_customer',
  'customers.view_asset',
  'discounts.view_discountrule',
  'expenses.view_expense',
  'treasury.view_moneyaccount',
  'treasury.view_moneytransfer',
  'treasury.view_moneycount',
  'catalog.view_product',
  'catalog.view_productcategory',
  'catalog.view_unitofmeasure',
  'catalog.view_scalebarcoderule',
  'operations.view_job',
};

/// المحاسب: the one role besides the manager that keeps the treasury and the
/// expense categories. It reads supplier payments and does not record them.
const accountantPermissions = <String>{
  'integrations.record_integration_topup',
  'auth.view_user',
  'core.view_shopsettings',
  'fx.view_currency',
  'fx.view_exchangerate',
  'fx.add_exchangerate',
  'analytics.view_analyticsevent',
  'customers.view_customer',
  'discounts.view_discountrule',
  'employees.add_compensationplan',
  'employees.change_compensationplan',
  'employees.view_compensationplan',
  'employees.add_employee',
  'employees.change_employee',
  'employees.view_employee',
  'employees.view_employeeloan',
  'employees.change_employeeloan',
  'employees.approve_employeeloan',
  'employees.reject_employeeloan',
  'employees.add_payrollrun',
  'employees.change_payrollrun',
  'employees.view_payrollrun',
  'employees.approve_payrollrun',
  'employees.mark_payrollrun_paid',
  'employees.void_payrollrun',
  'payments.view_payment',
  'purchasing.view_purchaseorder',
  'purchasing.view_supplier',
  'purchasing.view_supplierpayment',
  'reports.view_reportrun',
  'reports.manage_period_lock',
  'sales.view_order',
  'sales.view_registersession',
  'sales.view_registercashmovement',
  'inventory.view_stockitem',
  'inventory.view_warehouse',
  'inventory.view_stocktransfer',
  'sales.view_registerprofile',
  'inventory.view_stockmovement',
  'inventory.view_stockcount',
  'catalog.view_product',
  'catalog.view_productcategory',
  'catalog.view_unitofmeasure',
  'catalog.view_scalebarcoderule',
  'expenses.add_expense',
  'expenses.change_expense',
  'expenses.delete_expense',
  'expenses.view_expense',
  'expenses.add_expensecategory',
  'expenses.change_expensecategory',
  'expenses.delete_expensecategory',
  'expenses.view_expensecategory',
  'treasury.view_moneyaccount',
  'treasury.add_moneyaccount',
  'treasury.change_moneyaccount',
  'treasury.view_moneytransfer',
  'treasury.add_moneytransfer',
  'treasury.view_moneycount',
  'treasury.add_moneycount',
  'attendance.view_biotimeconnection',
  'attendance.change_biotimeconnection',
  'attendance.view_attendanceprofile',
  'attendance.change_attendanceprofile',
  'attendance.view_attendancepunch',
  'attendance.view_attendanceday',
};

/// Signed in as [role], holding [permissions]: the role's bundle plus any
/// per-user extras — which is what the backend sends as effective permissions.
PosUser userWithRole(UserRole role, Set<String> permissions) {
  return PosUser(
    id: 9,
    username: 'staff',
    displayName: 'موظف',
    role: role,
    isActive: true,
    permissions: permissions,
  );
}

AuthorizationCapabilities capabilitiesFor(
  UserRole role,
  Set<String> permissions,
) {
  return AuthorizationCapabilities.forUser(userWithRole(role, permissions));
}

/// Holds every capability, whatever its permission list says.
const managerUser = PosUser(
  id: 1,
  username: 'owner',
  displayName: 'المالك',
  role: UserRole.manager,
  isActive: true,
);
