/// Turns a rejected API response into something a person can act on.
///
/// Every 4xx this backend sends carries a reason — `detail`, a per-field map, a
/// machine `code` — and until now almost none of it reached the screen. The
/// field cost of that is measurable: on 4–5 September 2026 one shop hit a 400
/// on `PATCH /api/purchase-orders/` **41 times** across two orders and a 400 on
/// register close **21 times** in thirty-five seconds, mashing the button
/// because the app said only that something had failed. The server knew why
/// every single time.
///
/// Shapes handled, because DRF emits all of them:
///
/// * `{"detail": "Register session is already closed."}`
/// * `{"code": "recorder_cooling_down", "detail": "..."}`
/// * `{"quantity": ["Quantity must be positive."]}`
/// * `{"non_field_errors": ["..."]}`
/// * `{"lines": [{"unit_cost": ["..."]}, {}]}` — indexed rows, blanks skipped
library;

import 'api_session.dart';

/// The HTTP status, when the failure was an API response at all.
int? apiStatusCode(Object? error) =>
    error is PosApiException ? error.statusCode : null;

/// The machine-readable `code` a response chose to name itself with.
///
/// Distinct from the message: codes are for branching (retry, refresh, confirm),
/// messages are for reading.
String? apiErrorCode(Object? error) {
  final body = _decodedMap(error);
  final code = body?['code'];
  return code is String && code.isNotEmpty ? code : null;
}

/// A short human-readable reason, or empty when the body carried none.
///
/// Empty rather than a placeholder on purpose — a caller that gets nothing back
/// should fall back to its own wording rather than show "null" or "Exception".
String apiErrorDetail(Object? error, {int maxParts = 3}) {
  final body = _decodedMap(error);
  if (body == null) {
    return '';
  }

  final parts = <String>[];

  void add(Object? value) {
    if (parts.length >= maxParts) {
      return;
    }
    for (final message in _messagesIn(value)) {
      if (message.isEmpty || parts.contains(message)) {
        continue;
      }
      parts.add(message);
      if (parts.length >= maxParts) {
        return;
      }
    }
  }

  // `detail` and `non_field_errors` first: when a view bothered to write one,
  // it is the sentence that explains the refusal.
  add(body['detail']);
  add(body['non_field_errors']);

  for (final entry in body.entries) {
    if (parts.length >= maxParts) {
      break;
    }
    // `code` is for branching, not reading; the two above are already in.
    if (entry.key == 'detail' ||
        entry.key == 'non_field_errors' ||
        entry.key == 'code') {
      continue;
    }
    add(entry.value);
  }

  return parts.join(' · ');
}

Map<String, Object?>? _decodedMap(Object? error) {
  if (error is! PosApiException) {
    return null;
  }
  final decoded = error.decodedBody;
  return decoded is Map<String, Object?> ? decoded : null;
}

/// Flattens the arbitrarily nested lists and maps DRF builds for nested
/// serializers down to the leaf strings, which are the only readable part.
Iterable<String> _messagesIn(Object? value, {int depth = 0}) sync* {
  if (depth > 4) {
    return;
  }
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      yield trimmed;
    }
    return;
  }
  if (value is List) {
    for (final item in value) {
      yield* _messagesIn(item, depth: depth + 1);
    }
    return;
  }
  if (value is Map) {
    for (final item in value.values) {
      yield* _messagesIn(item, depth: depth + 1);
    }
  }
}
