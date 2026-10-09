/// Reading JSON that a server may have left out or sent malformed.
///
/// The direct-service payloads (airtime, bill payments) come from a relay's
/// directory of hundreds of operators and billers: one bad entry must cost the
/// till that entry, never the whole screen. Every reader here answers an empty
/// value instead of throwing.
library;

/// Text, trimmed; empty for anything absent.
String jsonText(Object? raw) => raw == null ? '' : raw.toString().trim();

/// A whole number; zero for anything unreadable.
int jsonInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString().trim() ?? '') ?? 0;
}

/// A number, or null when absent or unreadable. Accepts the decimal strings the
/// relay sends money and amounts as.
double? jsonDouble(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

/// A plain decimal string as the relay wrote it ("5000", "1967.50"), or empty.
/// Kept as text because it is sent back to the relay exactly as it arrived.
String jsonDecimalText(Object? raw) {
  if (raw == null) return '';
  if (raw is num) {
    return raw == raw.roundToDouble() ? raw.toInt().toString() : '$raw';
  }
  return raw.toString().trim();
}

DateTime? jsonDate(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw.trim())?.toLocal();
}

Map<String, Object?>? jsonMap(Object? raw) {
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) {
    return {for (final entry in raw.entries) entry.key.toString(): entry.value};
  }
  return null;
}

/// Every map in [raw] that [parse] accepts. An entry that is not a map, or
/// that [parse] throws on, is skipped.
List<T> jsonList<T>(Object? raw, T Function(Map<String, Object?> json) parse) {
  if (raw is! List) {
    return const [];
  }
  final parsed = <T>[];
  for (final entry in raw) {
    final map = jsonMap(entry);
    if (map == null) {
      continue;
    }
    try {
      parsed.add(parse(map));
    } on Object {
      continue;
    }
  }
  return parsed;
}

/// The strings of a list, trimmed, blanks dropped.
List<String> jsonTexts(Object? raw) {
  if (raw is! List) {
    return const [];
  }
  return [
    for (final entry in raw)
      if (jsonText(entry).isNotEmpty) jsonText(entry),
  ];
}
