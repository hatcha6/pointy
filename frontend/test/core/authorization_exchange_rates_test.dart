import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

AuthorizationCapabilities _user(UserRole role, Set<String> permissions) =>
    AuthorizationCapabilities.forUser(
      PosUser(
        id: 7,
        username: role.name,
        role: role,
        isActive: true,
        permissions: permissions,
      ),
    );

void main() {
  test(
    'a till user reads rates (the converter) but gets no rates workbench',
    () {
      final cashier = _user(UserRole.cashier, const {
        'fx.view_exchangerate',
        'fx.view_currency',
      });
      expect(cashier.canViewExchangeRates, isTrue);
      expect(cashier.canRecordExchangeRates, isFalse);
    },
  );

  test('whoever may type a rate also gets the rates page', () {
    final accountant = _user(UserRole.accountant, const {
      'fx.view_exchangerate',
      'fx.add_exchangerate',
    });
    expect(accountant.canViewExchangeRates, isTrue);
    expect(accountant.canRecordExchangeRates, isTrue);
  });

  test('the manager has both', () {
    final owner = _user(UserRole.manager, const {});
    expect(owner.canViewExchangeRates, isTrue);
    expect(owner.canRecordExchangeRates, isTrue);
  });
}
