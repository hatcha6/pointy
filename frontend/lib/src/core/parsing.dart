// Parsing helpers for user-entered numbers.
//
// Pointy is Arabic-first and runs on devices with Arabic keyboards, so a money
// or quantity field can arrive with Arabic-Indic digits (٠-٩), a comma (or the
// Arabic ٫) decimal separator, or stray whitespace. [parseDecimal] normalises
// all of that to a plain [double] — the many hand-rolled
// `replaceAll(',', '.')` + `double.tryParse` snippets across the app should
// funnel through here so the rules stay in one place.

/// Parses a localized decimal string to a [double], or returns `null` when the
/// input is blank or not a number. Handles Arabic-Indic / Persian digits, a
/// comma or dot (or Arabic `٫`) decimal separator, and surrounding whitespace.
double? parseDecimal(String? input) {
  if (input == null) {
    return null;
  }
  final normalized = _normalizeDigits(input).trim();
  if (normalized.isEmpty) {
    return null;
  }
  // Pointy's number fields don't use grouping separators, so a comma can only
  // be a decimal point.
  return double.tryParse(normalized.replaceAll(',', '.'));
}

/// Like [parseDecimal] but falls back to [fallback] (default `0`) when the input
/// can't be parsed — for fields where an empty or garbage value means "zero".
double parseDecimalOr(String? input, [double fallback = 0]) {
  return parseDecimal(input) ?? fallback;
}

String _normalizeDigits(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      // Arabic-Indic digits ٠-٩ → 0-9.
      buffer.writeCharCode(0x30 + (rune - 0x0660));
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      // Extended Arabic-Indic (Persian) digits ۰-۹ → 0-9.
      buffer.writeCharCode(0x30 + (rune - 0x06F0));
    } else if (rune == 0x066B) {
      // Arabic decimal separator ٫ → '.'.
      buffer.writeCharCode(0x2E);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}
