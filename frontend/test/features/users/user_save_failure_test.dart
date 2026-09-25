import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/features/users/user_save_failure.dart';

/// One generic line used to stand in for every refusal, which is how a
/// username that was already taken came to be reported as "creating a
/// supervisor fails": the second test account reused the first one's name.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  PosApiException refusal(String body, {int status = 400}) => PosApiException(
    message: 'User create failed with status $status',
    statusCode: status,
    responseBody: body,
  );

  test('a taken username is named as such and pinned to the field', () {
    final failure = UserSaveFailure.fromError(
      refusal('{"username": ["A user with that username already exists."]}'),
    )!;

    expect(failure.isUsernameTaken, isTrue);
    expect(failure.describe(l10n), l10n.usernameTakenError);
    expect(failure.usernameMessage(l10n), l10n.usernameTakenError);
  });

  test('a role beyond the acting admin explains the guard', () {
    final failure = UserSaveFailure.fromError(
      refusal(
        '{"role": ["You can only assign a role whose permissions you hold '
        'yourself."]}',
      ),
    )!;

    expect(failure.isRoleBeyondActor, isTrue);
    expect(failure.describe(l10n), l10n.userRoleNotAssignableError);
    expect(failure.usernameMessage(l10n), isNull);
  });

  test('a permission beyond the acting admin explains the guard', () {
    final failure = UserSaveFailure.fromError(
      refusal(
        '{"extra_permissions": ["You can only grant permissions you hold '
        'yourself: employees.approve_payrollrun."]}',
      ),
    )!;

    expect(failure.describe(l10n), l10n.userPermissionsNotGrantableError);
  });

  test('editing a richer account explains the guard', () {
    final failure = UserSaveFailure.fromError(
      refusal(
        '{"non_field_errors": ["You cannot edit a user who holds permissions '
        'you do not."]}',
      ),
    )!;

    expect(failure.describe(l10n), l10n.userEditRicherAccountError);
  });

  test('an unrecognised refusal still reaches the admin verbatim', () {
    final failure = UserSaveFailure.fromError(
      refusal('{"email": ["Enter a valid email address."]}'),
    )!;

    expect(failure.describe(l10n), 'Enter a valid email address.');
    expect(failure.usernameMessage(l10n), isNull);
  });

  test('a detail sentence wins when no field is named', () {
    final failure = UserSaveFailure.fromError(
      refusal('{"detail": "هذا الحساب لا يمكن تعديله."}', status: 403),
    )!;

    expect(failure.describe(l10n), 'هذا الحساب لا يمكن تعديله.');
  });

  test('a failure with no readable reason carries none', () {
    expect(UserSaveFailure.fromError(Exception('connection reset')), isNull);
    expect(
      UserSaveFailure.fromError(refusal('<html>502</html>', status: 502)),
      isNull,
    );
    expect(UserSaveFailure.fromError(refusal('{"username": []}')), isNull);
  });
}
