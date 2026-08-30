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

/// The backend's own sentence for a failed call, when the response carries one.
///
/// DRF puts a human message in `detail` (our views write Arabic there), while
/// field validation arrives as `{"field": ["message", ...]}`. Returns null for
/// anything else — a transport failure, HTML from a proxy, an empty 5xx — so the
/// caller falls back to its own localized copy instead of showing the developer
/// string that [PosApiException.message] carries.
String? backendDetailFor(Object error) {
  if (error is! PosApiException) {
    return null;
  }
  final decoded = error.decodedBody;
  if (decoded is! Map) {
    return null;
  }
  final detail = decoded['detail'];
  final candidate =
      detail ?? (decoded.values.isEmpty ? null : decoded.values.first);
  final text = switch (candidate) {
    String value => value,
    List value when value.isNotEmpty => value.first?.toString() ?? '',
    _ => '',
  };
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}
