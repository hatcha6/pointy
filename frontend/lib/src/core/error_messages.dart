import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/services/api_session.dart';

/// Turns any thrown [error] into a user-safe, localized message.
///
/// Arabic text the error carries is shown as-is: the backend's own sentence
/// when it wrote one in Arabic, else an Arabic [PosApiException.message].
/// Anything else falls back to localized copy — a 5xx to the server message,
/// the rest to the generic one. Use this instead of leaking `error.toString()`
/// into the UI.
///
/// Only Arabic text is ever passed through. `throwApiException` fills
/// [PosApiException.message] with a developer string ("… failed with status
/// 400"), and the backend answers many refusals in English or with codes
/// ("switched_off"). Showing those put English on Arabic screens — integration
/// errors did exactly that.
///
/// Device/transport errors (printer connection failures, etc.) are intentionally
/// left to their callers, where the raw text is the useful diagnostic.
String errorMessageFor(Object error, AppLocalizations l10n) {
  if (error is PosApiException) {
    final detail = backendDetailFor(error);
    if (detail != null && _isArabic(detail)) {
      return detail;
    }
    final message = error.message.trim();
    if (_isArabic(message)) {
      return message;
    }
    if (error.statusCode >= 500) {
      return l10n.errorServerMessage;
    }
  }
  return l10n.errorUnexpectedMessage;
}

final _arabicLetter = RegExp('[\u0600-\u06FF]');

bool _isArabic(String text) => _arabicLetter.hasMatch(text);

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
