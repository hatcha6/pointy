String _currencySymbol = 'د.ل';

/// The currency symbol [formatMoney] renders next to amounts. Defaults to the
/// Libyan dinar until [configureCurrencySymbol] runs from the loaded shop
/// settings.
String get currencySymbol => _currencySymbol;

/// Sets the app-wide currency symbol from the shop settings. Call once after the
/// settings load; a blank value is ignored so the default stays in place.
void configureCurrencySymbol(String symbol) {
  final trimmed = symbol.trim();
  if (trimmed.isNotEmpty) {
    _currencySymbol = trimmed;
  }
}

String formatMoney(double value) =>
    '${value.toStringAsFixed(2)} $_currencySymbol';

/// A clean numeric string for text-to-speech: no currency symbol and no noisy
/// trailing zeros, so a screen reader says "8" and "2.5" rather than "8.00" and
/// "2.50". Accepts the API's stringly-typed price and falls back to the raw
/// text if it isn't a number.
String formatSpokenMoney(String rawValue) {
  final value = double.tryParse(rawValue.trim());
  if (value == null) {
    return rawValue.trim();
  }
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
