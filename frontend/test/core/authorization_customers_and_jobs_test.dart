import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

/// A cashier with the permissions their role carries, plus [extra].
AuthorizationCapabilities _cashierWith(Set<String> extra) {
  return AuthorizationCapabilities.forUser(
    PosUser(
      id: 3,
      username: 'counter',
      role: UserRole.cashier,
      isActive: true,
      permissions: {
        'sales.add_order',
        'operations.view_job',
        'operations.add_job',
        'operations.change_job',
        ...extra,
      },
    ),
  );
}

void main() {
  group('customers', () {
    test('adding customers does not open the contact book or a dashboard', () {
      // Field export, 2026-09-25: a cashier given "add customers" so the repair
      // counter could take in a walk-in's phone landed, at the next sign-in, on
      // a dashboard of every customer's balance.
      final capabilities = _cashierWith({'customers.add_customer'});

      expect(capabilities.canCreateCustomers, isTrue);
      expect(capabilities.canViewDashboard, isFalse);
      expect(capabilities.canViewCustomerDashboard, isFalse);
      expect(capabilities.canManageContacts, isFalse);
    });

    test('editing or deleting without viewing opens nothing either', () {
      final capabilities = _cashierWith({
        'customers.change_customer',
        'customers.delete_customer',
        'purchasing.add_supplier',
      });

      expect(capabilities.canViewDashboard, isFalse);
      expect(capabilities.canManageContacts, isFalse);
      expect(capabilities.canCreateCustomers, isFalse);
    });

    test('viewing customers is what opens the book and its totals', () {
      final capabilities = _cashierWith({'customers.view_customer'});

      expect(capabilities.canManageContacts, isTrue);
      expect(capabilities.canViewCustomerDashboard, isTrue);
      expect(capabilities.canViewDashboard, isTrue);
    });

    test('a manager can do all of it', () {
      final capabilities = AuthorizationCapabilities.forUser(
        const PosUser(
          id: 1,
          username: 'owner',
          role: UserRole.manager,
          isActive: true,
        ),
      );

      expect(capabilities.canCreateCustomers, isTrue);
      expect(capabilities.canManageContacts, isTrue);
      expect(capabilities.canChangeJobs, isTrue);
    });
  });

  group('jobs', () {
    test('changing jobs follows the permission the server checks', () {
      expect(_cashierWith(const {}).canChangeJobs, isTrue);

      final viewer = AuthorizationCapabilities.forUser(
        const PosUser(
          id: 4,
          username: 'auditor',
          role: UserRole.cashier,
          isActive: true,
          permissions: {'operations.view_job'},
        ),
      );
      expect(viewer.canViewOperations, isTrue);
      expect(viewer.canChangeJobs, isFalse);
    });
  });
}
