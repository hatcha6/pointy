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

String formatMoney(double value) => '${value.toStringAsFixed(2)} $_currencySymbol';
