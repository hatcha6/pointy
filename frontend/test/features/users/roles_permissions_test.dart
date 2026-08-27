import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/permission_catalog.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

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
