/// Amounts in another country's currency, as the cashier reads them off the
/// screen and types them in: «5,000» francs, «2,500.5» naira — grouped in
/// thousands, no decimals nobody needs.
library;

import 'arabic_search_text.dart';

/// [value] with thousands separators and only the decimals it has, up to
/// [maxDecimals]: 5000 → `5,000`, 2500.5 → `2,500.5`, 1967 → `1,967`.
String formatForeignAmount(num value, {int maxDecimals = 2}) {
  final fixed = value.toDouble().toStringAsFixed(maxDecimals);
  final negative = fixed.startsWith('-');
  final unsigned = negative ? fixed.substring(1) : fixed;
  final point = unsigned.indexOf('.');
  final whole = point < 0 ? unsigned : unsigned.substring(0, point);
  var fraction = point < 0 ? '' : unsigned.substring(point + 1);
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) {
      grouped.write(',');
    }
    grouped.write(whole[i]);
  }
  final text = fraction.isEmpty ? '$grouped' : '$grouped.$fraction';
  return negative ? '-$text' : text;
}

/// A wire amount (`"5000"`, `"1967.50"`) as the screen shows it, or the text
/// itself when it is not a number.
String formatForeignAmountText(String amount, {int maxDecimals = 2}) {
  final value = double.tryParse(amount.trim());
  return value == null
      ? amount.trim()
      : formatForeignAmount(value, maxDecimals: maxDecimals);
}

/// What a cashier typed as an amount, read as a number: Arabic digits, a
/// `.`, `,` or the Arabic decimal separator for decimals, thousands separated
/// by `,`, the Arabic thousands separator or spaces.
///
/// `5,000` is five thousand, `5,5` is five and a half: a comma followed by
/// exactly three digits and nothing after is grouping; otherwise it is a
/// decimal point. Null for anything that is not a plain positive number.
double? parseTypedAmount(String raw) {
  final canonical = canonicalAmountText(raw);
  if (canonical == null) {
    return null;
  }
  final value = double.tryParse(canonical);
  return value == null || value <= 0 ? null : value;
}

/// [raw] as the plain decimal string the relay takes — `5000`, `2500.5` — or
/// null when it is not an amount. Never more than 2 decimals.
String? canonicalAmountText(String raw) {
  var text = asciiDigits(raw)
      .replaceAll('\u{066C}', ',')
      .replaceAll('\u{066B}', '.')
      .replaceAll(RegExp('[\\s\u{00A0}\u{2066}-\u{2069}\u{200E}\u{200F}]'), '');
  if (text.isEmpty || !RegExp(r'^[0-9.,]+$').hasMatch(text)) {
    return null;
  }
  final lastDot = text.lastIndexOf('.');
  final lastComma = text.lastIndexOf(',');
  String whole;
  String fraction = '';
  if (lastDot >= 0 && lastComma >= 0) {
    // Both: the later one is the decimal point, the other groups thousands.
    final point = lastDot > lastComma ? lastDot : lastComma;
    whole = text.substring(0, point).replaceAll(RegExp(r'[.,]'), '');
    fraction = text.substring(point + 1);
  } else if (lastComma >= 0 || lastDot >= 0) {
    final separator = lastComma >= 0 ? ',' : '.';
    final parts = text.split(separator);
    final after = parts.last;
    final groupingOnly =
        separator == ',' &&
        parts.length > 1 &&
        parts.skip(1).every((part) => part.length == 3);
    if (groupingOnly) {
      whole = parts.join();
    } else if (parts.length == 2) {
      whole = parts.first;
      fraction = after;
    } else {
      return null;
    }
  } else {
    whole = text;
  }
  if (whole.isEmpty) {
    whole = '0';
  }
  if (fraction.length > 2 || !RegExp(r'^[0-9]*$').hasMatch(fraction)) {
    return null;
  }
  whole = whole.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  text = fraction.isEmpty ? whole : '$whole.$fraction';
  return text;
}
