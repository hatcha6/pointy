import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

AuthorizationCapabilities _capabilities({
  UserRole role = UserRole.supervisor,
  Set<String> permissions = const {},
  bool serialized = true,
}) {
  return AuthorizationCapabilities.forUser(
    PosUser(
      id: 1,
      username: 'someone',
      role: role,
      isActive: true,
      permissions: permissions,
      serializedInventoryEnabled: serialized,
    ),
  );
}

/// «قوائم فحص الأجهزة» is the owner's: editing what every received handset is
/// asked about. Granted by `inventory.manage_unitattributedefinition`, and —
/// like every identified-stock surface — gone while serials are off.
void main() {
  test('a manager edits the checklists once serials are on', () {
    expect(
      _capabilities(role: UserRole.manager).canManageUnitAttributes,
      isTrue,
    );
    expect(
      _capabilities(
        role: UserRole.manager,
        serialized: false,
      ).canManageUnitAttributes,
      isFalse,
    );
  });

  test('the permission grants it, in either spelling', () {
    for (final code in const [
      'inventory.manage_unitattributedefinition',
      'manage_unitattributedefinition',
    ]) {
      expect(
        _capabilities(permissions: {code}).canManageUnitAttributes,
        isTrue,
        reason: code,
      );
    }
  });

  test('seeing or describing units is not designing the checklist', () {
    final counter = _capabilities(
      role: UserRole.cashier,
      permissions: const {
        'inventory.view_stockunit',
        'inventory.change_stockunit',
      },
    );

    expect(counter.canEditStockUnitAttributes, isTrue);
    expect(counter.canManageUnitAttributes, isFalse);
  });

  test('a held permission does not conjure it while serials are off', () {
    expect(
      _capabilities(
        permissions: const {'inventory.manage_unitattributedefinition'},
        serialized: false,
      ).canManageUnitAttributes,
      isFalse,
    );
  });
}
