import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// The part of the server's username rule the form can check before sending.
///
/// Django takes letters (Arabic included), digits and `. @ + - _` — never a
/// space. A space is the mistake people actually make, typing a full name
/// where the username goes: an admin in the field retried one five times in
/// twenty seconds against an English refusal (2026-09-24). Anything subtler is
/// left to the server, whose refusal [UserSaveFailure] translates. Blank is
/// not judged here; "required" is each field's own rule.
String? usernameFormatError(AppLocalizations l10n, String? value) {
  final username = (value ?? '').trim();
  if (username.isEmpty || !username.contains(RegExp(r'\s'))) {
    return null;
  }
  return l10n.usernameInvalidError;
}
