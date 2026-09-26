import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/permission_catalog.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

import '../../shared/role_fixtures.dart';

void main() {
  group('UserRole', () {
    test('round-trips every assignable role through JSON', () {
      for (final role in UserRole.assignable) {
        expect(UserRole.fromJson(role.toJson()), role);
      }
    });

    test('maps the new backend role slugs', () {
      expect(UserRole.fromJson('supervisor'), UserRole.supervisor);
      expect(UserRole.fromJson('inventory_clerk'), UserRole.inventoryClerk);
      expect(UserRole.fromJson('purchasing_agent'), UserRole.purchasingAgent);
      expect(UserRole.fromJson('auditor'), UserRole.auditor);
    });

    test('falls back to cashier for unknown values', () {
      expect(UserRole.fromJson('wizard'), UserRole.cashier);
      expect(UserRole.fromJson(null), UserRole.cashier);
    });
  });

  group('PosUser.fromJson', () {
    test('parses role, effective/role/extra permissions and extra count', () {
      final user = PosUser.fromJson(const {
        'id': 7,
        'username': 'sam',
        'assigned_role': 'inventory_clerk',
        'is_active': true,
        'role_permissions': [
          'inventory.view_stockitem',
          'inventory.add_stockcount',
        ],
        'extra_permissions': ['payments.view_payment'],
        'effective_permissions': [
          'inventory.view_stockitem',
          'inventory.add_stockcount',
          'payments.view_payment',
        ],
        'extra_permission_count': 1,
      });

      expect(user.role, UserRole.inventoryClerk);
      expect(user.rolePermissions, contains('inventory.add_stockcount'));
      expect(user.extraPermissions, {'payments.view_payment'});
      expect(user.extraPermissionCount, 1);
      expect(user.hasExtraPermissions, isTrue);
      expect(user.permissions, contains('payments.view_payment'));
    });

    test('extra count falls back to the extra list length', () {
      final user = PosUser.fromJson(const {
        'id': 1,
        'username': 'a',
        'assigned_role': 'cashier',
        'extra_permissions': ['inventory.apply_stockcount'],
      });
      expect(user.extraPermissionCount, 1);
      expect(user.hasExtraPermissions, isTrue);
    });
  });

  group('AuthorizationCapabilities', () {
    PosUser cashierWith(List<String> effective) => PosUser.fromJson({
      'id': 2,
      'username': 'till',
      'assigned_role': 'cashier',
      'is_active': true,
      'effective_permissions': effective,
    });

    test('a directly-granted permission flows into a capability', () {
      final caps = AuthorizationCapabilities.forUser(
        cashierWith(const ['inventory.apply_stockcount']),
      );
      expect(caps.canApplyStockCount, isTrue);
    });

    test('reopen_job grant maps to the reopenJobs capability', () {
      final caps = AuthorizationCapabilities.forUser(
        cashierWith(const ['operations.view_job', 'operations.reopen_job']),
      );
      expect(caps.canReopenJobs, isTrue);
      expect(caps.canViewOperations, isTrue);
    });

    test('a write grant opens the screen that holds its buttons', () {
      // Each of these is grantable from the permission editor, and each
      // screen's buttons sit behind one coarse capability. Without the
      // mapping, the grant would be a right with no way to reach it.
      final screens = <String, bool Function(AuthorizationCapabilities)>{
        'catalog.add_unitofmeasure': (caps) => caps.canViewCatalogManagement,
        'catalog.change_scalebarcoderule': (caps) =>
            caps.canViewCatalogManagement,
        'catalog.add_billofmaterials': (caps) => caps.canManageRecipes,
        'catalog.delete_billofmaterials': (caps) => caps.canManageRecipes,
        'scales.change_scale': (caps) => caps.canManageScales,
        'price_checker.add_pricecheckerdevice': (caps) =>
            caps.canManagePriceCheckers,
        'surveillance.add_recorder': (caps) => caps.canManageCameras,
      };
      final without = AuthorizationCapabilities.forUser(cashierWith(const []));
      for (final MapEntry(key: code, value: opens) in screens.entries) {
        final granted = AuthorizationCapabilities.forUser(cashierWith([code]));
        expect(opens(granted), isTrue, reason: code);
        expect(opens(without), isFalse, reason: code);
      }
    });

    test('a plain cashier gets neither', () {
      final caps = AuthorizationCapabilities.forUser(cashierWith(const []));
      expect(caps.canApplyStockCount, isFalse);
      expect(caps.canReopenJobs, isFalse);
    });

    test('manager gets every capability including new ones', () {
      final manager = PosUser.fromJson(const {
        'id': 1,
        'username': 'boss',
        'assigned_role': 'manager',
        'is_active': true,
      });
      final caps = AuthorizationCapabilities.forUser(manager);
      expect(caps.canManageUsers, isTrue);
      expect(caps.canReopenJobs, isTrue);
      expect(caps.canApplyStockCount, isTrue);
    });

    // The permission editor's warehouses group grants these one at a time, so
    // each has to land on its own capability and on none of its neighbours.
    final warehouseGrants = <String, bool Function(AuthorizationCapabilities)>{
      'inventory.view_warehouse': (caps) => caps.canViewWarehouses,
      'inventory.add_warehouse': (caps) => caps.canCreateWarehouse,
      'inventory.change_warehouse': (caps) => caps.canChangeWarehouse,
      'inventory.delete_warehouse': (caps) => caps.canDeleteWarehouse,
      'sales.change_registerprofile': (caps) => caps.canChangeRegisterWarehouse,
      'inventory.view_stocktransfer': (caps) => caps.canViewStockTransfers,
      'inventory.dispatch_stocktransfer': (caps) =>
          caps.canDispatchStockTransfer,
      'inventory.receive_stocktransfer': (caps) => caps.canReceiveStockTransfer,
    };

    test('each warehouse and transfer grant maps to its own capability', () {
      for (final code in warehouseGrants.keys) {
        // Bare codenames too, as every rule in forUser accepts both forms.
        for (final granted in [code, code.split('.').last]) {
          final caps = AuthorizationCapabilities.forUser(
            cashierWith([granted]),
          );
          for (final MapEntry(key: other, value: holds)
              in warehouseGrants.entries) {
            expect(holds(caps), other == code, reason: '$granted → $other');
          }
          // Nor is any of them the sales-channel right the settings tiles
          // used to borrow.
          expect(caps.canManageSalesChannels, isFalse, reason: granted);
        }
      }
    });

    test('writing a transfer also needs the stock its composer picks from', () {
      bool canCreate(List<String> granted) => AuthorizationCapabilities.forUser(
        cashierWith(granted),
      ).canCreateStockTransfer;

      expect(canCreate(const ['inventory.add_stocktransfer']), isFalse);
      expect(canCreate(const ['inventory.view_stockitem']), isFalse);
      expect(
        canCreate(const [
          'inventory.add_stocktransfer',
          'inventory.view_stockitem',
        ]),
        isTrue,
      );
      expect(canCreate(const ['add_stocktransfer', 'view_stockitem']), isTrue);
    });

    test('a manager keeps every warehouse and transfer action', () {
      final caps = AuthorizationCapabilities.forUser(
        const PosUser(
          id: 1,
          username: 'boss',
          role: UserRole.manager,
          isActive: true,
        ),
      );
      for (final MapEntry(key: code, value: holds) in warehouseGrants.entries) {
        expect(holds(caps), isTrue, reason: code);
      }
      expect(caps.canCreateStockTransfer, isTrue);
    });
  });

  // Each of these buttons was offered on data or screen access alone, while the
  // server asks for a permission of its own — so whoever could open the screen
  // without holding the write saw a button that could only answer 403.
  group('write actions follow the permission the server checks', () {
    test('a buyer runs a purchase order but does not pay for it', () {
      final caps = capabilitiesFor(
        UserRole.purchasingAgent,
        purchasingAgentPermissions,
      );

      expect(caps.canAccessPurchasing, isTrue);
      expect(caps.canReceivePurchaseOrder, isTrue);
      expect(caps.canRecordSupplierPayment, isFalse);
    });

    test('nobody but the manager pays a supplier by role', () {
      // Reading supplier payments is not recording one, and every role that
      // opens purchase orders reads them.
      expect(
        capabilitiesFor(
          UserRole.accountant,
          accountantPermissions,
        ).canRecordSupplierPayment,
        isFalse,
      );
      expect(
        capabilitiesFor(
          UserRole.auditor,
          auditorPermissions,
        ).canRecordSupplierPayment,
        isFalse,
      );
    });

    test('the supplier payment permission is what grants it', () {
      final granted = capabilitiesFor(UserRole.purchasingAgent, {
        ...purchasingAgentPermissions,
        'purchasing.add_supplierpayment',
      });
      expect(granted.canRecordSupplierPayment, isTrue);

      // It opens no screen: without reading purchase orders there is no
      // order to pay.
      final alone = capabilitiesFor(UserRole.cashier, {
        'purchasing.add_supplierpayment',
      });
      expect(alone.canRecordSupplierPayment, isTrue);
      expect(alone.canAccessPurchasing, isFalse);
    });

    test('an auditor reads the treasury and may move none of it', () {
      final caps = capabilitiesFor(UserRole.auditor, auditorPermissions);

      expect(caps.canViewPayments, isTrue);
      expect(caps.canViewMoneyAccounts, isTrue);
      expect(caps.canCreateMoneyAccount, isFalse);
      expect(caps.canChangeMoneyAccount, isFalse);
      expect(caps.canRecordMoneyTransfer, isFalse);
      expect(caps.canRecordMoneyCount, isFalse);
    });

    test('each treasury write grants its own button and no other', () {
      final writes = <String, bool Function(AuthorizationCapabilities)>{
        'treasury.add_moneyaccount': (caps) => caps.canCreateMoneyAccount,
        'treasury.change_moneyaccount': (caps) => caps.canChangeMoneyAccount,
        'treasury.add_moneytransfer': (caps) => caps.canRecordMoneyTransfer,
        'treasury.add_moneycount': (caps) => caps.canRecordMoneyCount,
      };
      for (final code in writes.keys) {
        final caps = capabilitiesFor(UserRole.auditor, {
          ...auditorPermissions,
          code,
        });
        for (final MapEntry(key: other, value: allows) in writes.entries) {
          expect(allows(caps), other == code, reason: '$code → $other');
        }
      }
    });

    test('the accountant keeps every treasury button', () {
      final caps = capabilitiesFor(UserRole.accountant, accountantPermissions);

      expect(caps.canCreateMoneyAccount, isTrue);
      expect(caps.canChangeMoneyAccount, isTrue);
      expect(caps.canRecordMoneyTransfer, isTrue);
      expect(caps.canRecordMoneyCount, isTrue);
    });

    test('recording expenses does not make someone keep the categories', () {
      final caps = capabilitiesFor(UserRole.auditor, {
        ...auditorPermissions,
        'expenses.add_expense',
        'expenses.change_expense',
        'expenses.delete_expense',
      });

      expect(caps.canManageExpenses, isTrue);
      expect(caps.canCreateExpenseCategory, isFalse);
      expect(caps.canChangeExpenseCategory, isFalse);
      expect(caps.canDeleteExpenseCategory, isFalse);
    });

    test('each expense category write grants its own action and no other', () {
      final writes = <String, bool Function(AuthorizationCapabilities)>{
        'expenses.add_expensecategory': (caps) => caps.canCreateExpenseCategory,
        'expenses.change_expensecategory': (caps) =>
            caps.canChangeExpenseCategory,
        'expenses.delete_expensecategory': (caps) =>
            caps.canDeleteExpenseCategory,
      };
      for (final code in writes.keys) {
        final caps = capabilitiesFor(UserRole.auditor, {
          ...auditorPermissions,
          code,
        });
        for (final MapEntry(key: other, value: allows) in writes.entries) {
          expect(allows(caps), other == code, reason: '$code → $other');
        }
      }
      final accountant = capabilitiesFor(
        UserRole.accountant,
        accountantPermissions,
      );
      expect(accountant.canCreateExpenseCategory, isTrue);
      expect(accountant.canChangeExpenseCategory, isTrue);
      expect(accountant.canDeleteExpenseCategory, isTrue);
    });

    test('the manager keeps every one of them', () {
      final caps = AuthorizationCapabilities.forUser(managerUser);

      expect(caps.canRecordSupplierPayment, isTrue);
      expect(caps.canCreateMoneyAccount, isTrue);
      expect(caps.canChangeMoneyAccount, isTrue);
      expect(caps.canRecordMoneyTransfer, isTrue);
      expect(caps.canRecordMoneyCount, isTrue);
      expect(caps.canCreateExpenseCategory, isTrue);
      expect(caps.canChangeExpenseCategory, isTrue);
      expect(caps.canDeleteExpenseCategory, isTrue);
    });
  });

  group('PermissionCatalog', () {
    test('parses groups, grantable codes and label map', () {
      final catalog = PermissionCatalog.fromJson(const {
        'groups': [
          {
            'key': 'inventory',
            'label': 'المخزون',
            'description': '',
            'permissions': [
              {
                'code': 'inventory.apply_stockcount',
                'label': 'اعتماد الجرد',
                'description': '',
                'grantable': true,
              },
              {
                'code': 'inventory.view_stockitem',
                'label': 'عرض المخزون',
                'description': '',
                'grantable': false,
              },
            ],
          },
        ],
      });

      expect(catalog.groups, hasLength(1));
      expect(catalog.totalCount, 2);
      expect(catalog.grantableCodes, {'inventory.apply_stockcount'});
      expect(catalog.labelsByCode['inventory.view_stockitem'], 'عرض المخزون');
    });
  });
}
