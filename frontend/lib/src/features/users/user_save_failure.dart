import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/services/api_session.dart';

/// Why the server refused to create or update a user, in the shape DRF
/// reports it: the first message per rejected field, plus a free-standing
/// `detail` sentence when the refusal was not about a field.
///
/// Until this existed every refusal collapsed into one generic line, so a
/// username that was already taken, a role the acting admin may not hand out
/// and a permission they do not hold themselves all read as "creating this
/// role fails" — and only the last two are about the role at all.
class UserSaveFailure {
  const UserSaveFailure({this.fieldMessages = const {}, this.detail});

  final Map<String, String> fieldMessages;
  final String? detail;

  static UserSaveFailure? fromError(Object error) {
    if (error is! PosApiException) {
      return null;
    }
    final decoded = error.decodedBody;
    if (decoded is! Map) {
      return null;
    }
    final fields = <String, String>{};
    String? detail;
    for (final entry in decoded.entries) {
      final text = _firstText(entry.value);
      if (text == null) {
        continue;
      }
      if (entry.key == 'detail') {
        detail = text;
      } else {
        fields['${entry.key}'] = text;
      }
    }
    if (fields.isEmpty && detail == null) {
      return null;
    }
    return UserSaveFailure(fieldMessages: fields, detail: detail);
  }

  static String? _firstText(Object? value) {
    final candidate = switch (value) {
      String text => text,
      List list when list.isNotEmpty => list.first?.toString() ?? '',
      _ => '',
    };
    final trimmed = candidate.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // The fragments below are the backend's own wording (Django's unique
  // check and PosUserSerializer's escalation guards). A message that does not
  // match still reaches the admin verbatim through [describe]; only the
  // translation is lost, never the reason.

  /// Another account already has this username.
  bool get isUsernameTaken => _mentions('username', 'already');

  /// The role carries permissions the acting admin does not hold.
  bool get isRoleBeyondActor => _mentions('role', 'hold yourself');

  /// A granted permission is one the acting admin does not hold.
  bool get isPermissionBeyondActor =>
      _mentions('extra_permissions', 'hold yourself');

  /// The edited account holds permissions the acting admin does not.
  bool get isTargetBeyondActor =>
      _mentions('non_field_errors', 'permissions you do not');

  bool _mentions(String field, String fragment) =>
      fieldMessages[field]?.toLowerCase().contains(fragment) ?? false;

  /// The sentence to show the admin, or null when nothing specific is known
  /// and the caller's own generic copy is the honest choice.
  String? describe(AppLocalizations l10n) {
    if (isUsernameTaken) {
      return l10n.usernameTakenError;
    }
    if (isRoleBeyondActor) {
      return l10n.userRoleNotAssignableError;
    }
    if (isPermissionBeyondActor) {
      return l10n.userPermissionsNotGrantableError;
    }
    if (isTargetBeyondActor) {
      return l10n.userEditRicherAccountError;
    }
    if (detail != null) {
      return detail;
    }
    return fieldMessages.values.isEmpty ? null : fieldMessages.values.first;
  }

  /// The sentence to hang on the username field itself, when the refusal
  /// concerned it.
  String? usernameMessage(AppLocalizations l10n) {
    if (isUsernameTaken) {
      return l10n.usernameTakenError;
    }
    return fieldMessages['username'];
  }
}
