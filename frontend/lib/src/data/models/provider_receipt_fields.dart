/// The printed slip a provider answered with (`receipt` on a charge result and
/// on a sale line), as the flat text map every slip builder reads.
///
/// Cards and top-ups send plain text fields (`code`, `serial`, `package`).
/// The direct services send ready-made rows as well — `rows`, a list of
/// `[label, value]` pairs — so new wording never needs a new till release.
/// A list cannot live in a text map, so it rides as JSON text under its own
/// key and [providerReceiptRows] reads it back.
library;

import 'dart:convert';

/// The key the pairs ride under.
const String providerReceiptRowsKey = 'rows';

/// [raw] as text fields: scalars as their text, a list or map as JSON text.
Map<String, String> providerReceiptFromJson(Object? raw) {
  if (raw is! Map) {
    return const {};
  }
  return {
    for (final entry in raw.entries)
      entry.key.toString(): switch (entry.value) {
        null => '',
        final List<Object?> list => jsonEncode(list),
        final Map<Object?, Object?> map => jsonEncode(map),
        final value => value.toString(),
      },
  };
}

/// The `[label, value]` pairs of a slip's `rows`, however they travelled:
/// the JSON text [providerReceiptFromJson] made, or nothing. Pairs with no
/// value are dropped; a pair with one entry is a line of its own.
List<List<String>> providerReceiptRows(Map<String, String> printed) {
  final text = (printed[providerReceiptRowsKey] ?? '').trim();
  if (text.isEmpty || !text.startsWith('[')) {
    return const [];
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) {
    return const [];
  }
  final rows = <List<String>>[];
  for (final entry in decoded) {
    if (entry is List) {
      final parts = [
        for (final part in entry)
          if (part != null && part.toString().trim().isNotEmpty)
            part.toString().trim(),
      ];
      if (parts.isNotEmpty) {
        rows.add(parts);
      }
    } else if (entry != null && entry.toString().trim().isNotEmpty) {
      rows.add([entry.toString().trim()]);
    }
  }
  return rows;
}
