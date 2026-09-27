import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';

import '../shared/fake_app_navigation.dart';
import '../shared/role_fixtures.dart';

/// The reports screen is the shop's books — profit, cost, cash — and it opens
/// for the reporting roles alone: the holders of `reports.view_reportrun`.
///
/// It used to open for anyone holding one of a report's *source* permissions.
/// Every cashier reads orders and payments to work the till, so every cashier
/// had the screen, and the gross profit on their own sales in it.
void main() {
  // What used to open the screen, one permission at a time.
  const sourcePermissions = [
    'sales.view_order',
    'sales.view_registersession',
    'payments.view_payment',
    'inventory.view_stockitem',
    'inventory.view_stockmovement',
    'purchasing.view_purchaseorder',
    'purchasing.view_supplier',
    'customers.view_customer',
    'discounts.view_discountrule',
  ];

  bool opensReports(UserRole role, Set<String> permissions) {
    final navigation = FakeAppNavigation(
      currentUser: userWithRole(role, permissions),
    );
    final byCapability = navigation.capabilities.canViewReports;
    // The drawer, ⌘K and the guides all ask the destination, not the flag.
    expect(
      navigation.isDestinationAvailable(AppNavigationDestination.reports),
      byCapability,
    );
    return byCapability;
  }

  test('reading what a report reads does not open the reports screen', () {
    for (final permission in sourcePermissions) {
      expect(
        opensReports(UserRole.cashier, {permission}),
        isFalse,
        reason: permission,
      );
    }
    expect(opensReports(UserRole.cashier, sourcePermissions.toSet()), isFalse);
  });

  test('a purchasing agent does not get it with the whole buying bundle', () {
    expect(
      opensReports(UserRole.purchasingAgent, purchasingAgentPermissions),
      isFalse,
    );
  });

  test('the reporting roles do', () {
    expect(opensReports(UserRole.accountant, accountantPermissions), isTrue);
    expect(opensReports(UserRole.auditor, auditorPermissions), isTrue);
    expect(
      opensReports(UserRole.supervisor, {'reports.view_reportrun'}),
      isTrue,
    );
    expect(
      AuthorizationCapabilities.forUser(managerUser).canViewReports,
      isTrue,
    );
  });

  test('granting the reporting permission to one person opens it', () {
    expect(
      opensReports(UserRole.cashier, {
        ...sourcePermissions,
        'reports.view_reportrun',
      }),
      isTrue,
    );
  });
}
