import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/services/api_session.dart';

/// Turns any thrown [error] into a user-safe, localized message.
///
/// Backend [PosApiException]s already carry Arabic-localized messages, so those
/// are shown as-is; a blank message or a 5xx response falls back to a localized
/// generic. Use this instead of leaking `error.toString()` into the UI.
///
/// Device/transport errors (printer connection failures, etc.) are intentionally
/// left to their callers, where the raw text is the useful diagnostic.
String errorMessageFor(Object error, AppLocalizations l10n) {
  if (error is PosApiException) {
    final message = error.message.trim();
    if (message.isNotEmpty) {
      return message;
    }
    if (error.statusCode >= 500) {
      return l10n.errorServerMessage;
    }
  }
  return l10n.errorUnexpectedMessage;
}
