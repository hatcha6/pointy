import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';

/// The user screen shows first and last name in one field, so saving it must
/// clear the last name — writing only first_name added the surname again on
/// every save (Annaseem 2026-10-12: «الحسين حمودة حمودة حمودة»).
void main() {
  test('a saved name clears the last name it already contains', () {
    final body = const UserUpdateDraft(displayName: 'الحسين حمودة').toJson();
    expect(body['first_name'], 'الحسين حمودة');
    expect(body['last_name'], '');
  });

  test('a save that does not touch the name leaves both alone', () {
    final body = const UserUpdateDraft(isActive: false).toJson();
    expect(body.containsKey('first_name'), isFalse);
    expect(body.containsKey('last_name'), isFalse);
  });

  test('a new user is stored the same way', () {
    final body = const UserCreateDraft(
      username: 'hussein',
      password: 'pass',
      role: UserRole.cashier,
      displayName: 'الحسين حمودة',
    ).toJson();
    expect(body['first_name'], 'الحسين حمودة');
    expect(body['last_name'], '');
  });
}
