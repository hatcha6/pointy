String _currencySymbol = 'د.ل';
String _baseCurrencyCode = 'LYD';

/// Symbols for currencies other than the shop's own, keyed by ISO code. Filled
/// in from the currency registry once it loads; a code with no entry renders as
/// the code itself, which is still readable.
Map<String, String> _foreignSymbols = const <String, String>{};

/// The currency symbol [formatMoney] renders next to amounts. Defaults to the
/// Libyan dinar until [configureCurrencySymbol] runs from the loaded shop
/// settings.
String get currencySymbol => _currencySymbol;

/// Sets the app-wide currency symbol from the shop settings. Call once after the
/// settings load; a blank value is ignored so the default stays in place.
///
/// [code] is the base currency's ISO code. It matters because a caller that
/// happens to hold the shop's own code — a rate quoted *into* it, say — must
/// still render the shop symbol rather than the bare letters.
void configureCurrencySymbol(String symbol, {String? code}) {
  final trimmed = symbol.trim();
  if (trimmed.isNotEmpty) {
    _currencySymbol = trimmed;
  }
  final trimmedCode = code?.trim().toUpperCase();
  if (trimmedCode != null && trimmedCode.isNotEmpty) {
    _baseCurrencyCode = trimmedCode;
  }
}

/// Registers the symbols for foreign currencies (from the currency registry).
void configureForeignCurrencySymbols(Map<String, String> symbols) {
  _foreignSymbols = <String, String>{
    for (final entry in symbols.entries)
      entry.key.trim().toUpperCase(): entry.value.trim(),
  }..removeWhere((_, value) => value.isEmpty);
}

/// The symbol for [code], falling back to the code itself.
String currencySymbolFor(String code) {
  final normalized = code.trim().toUpperCase();
  if (normalized.isEmpty || normalized == _baseCurrencyCode) {
    return _currencySymbol;
  }
  return _foreignSymbols[normalized] ?? normalized;
}

/// An amount in the shop's own currency — what every stored money value is in.
String formatMoney(double value) =>
    '${value.toStringAsFixed(2)} $_currencySymbol';

/// An amount in some other currency, e.g. an importer's dollar price sheet.
///
/// Kept separate from [formatMoney] deliberately: a caller that has a foreign
/// amount has to say so, rather than letting a dollar figure render with a
/// dinar symbol beside it.
String formatForeignMoney(
  double value,
  String currencyCode, {
  int decimals = 2,
}) => '${value.toStringAsFixed(decimals)} ${currencySymbolFor(currencyCode)}';

/// Unicode isolates. A price line mixes Latin digits with an Arabic symbol, and
/// in an RTL paragraph the bidi algorithm will otherwise reorder the two halves
/// of "12.00 $ ≈ 82.20 د.ل" into nonsense. Isolating each amount pins it.
const String _isolateStart = '\u2068'; // FIRST STRONG ISOLATE
const String _isolateEnd = '\u2069'; // POP DIRECTIONAL ISOLATE

String _isolated(String value) => '$_isolateStart$value$_isolateEnd';

/// Wraps a strictly left-to-right run — a host:port, an IMEI, a barcode — so it
/// keeps its own order inside an Arabic line without dragging the line with it.
///
/// This is the fix for a bug that looks like a layout mistake: setting
/// `textDirection: TextDirection.ltr` on a `Text` also flips what "start"
/// means for its alignment, so a stretched Text pins itself to the FAR LEFT of
/// its row, stranded from the icon and the label it belongs to. The isolate
/// pins only the characters, and leaves the line Arabic.
///
/// U+2066 (LEFT-TO-RIGHT ISOLATE) rather than the FIRST STRONG ISOLATE used
/// above: these runs open with digits, which are not strong, so first-strong
/// would resolve them to the surrounding RTL and reorder the very thing we are
/// protecting.
String ltrIsolated(String value) => '\u{2066}$value\u{2069}';

/// A foreign price and its base-currency equivalent, together.
///
/// Both halves, always. Showing only the converted figure hides the number the
/// owner actually maintains; showing only the foreign one hides what the
/// customer pays. The `≈` is honest too — the base price is what the shelf says,
/// and it moves only when someone reprices, so it is not a live conversion.
String formatDualPrice(
  double foreignAmount,
  String currencyCode,
  double baseAmount,
) {
  final foreign = _isolated(formatForeignMoney(foreignAmount, currencyCode));
  final base = _isolated(formatMoney(baseAmount));
  return '$foreign ≈ $base';
}

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

/// An exchange rate as the apps show it: "1 $ = 6.85 د.ل".
///
/// Rates are quoted to more places than money because a parallel-market rate
/// genuinely moves in the third decimal, and rounding it to two would make two
/// visibly different rates look identical.
String formatExchangeRate(double rate, String fromCode, String toCode) {
  final from = _isolated('1 ${currencySymbolFor(fromCode)}');
  return '$from = ${_isolated(formatRateQuote(rate, toCode))}';
}

/// Only the quoted side of a rate — "6.85 د.ل".
///
/// For surfaces that already say what is being quoted (a ticker tile headed
/// USD, say) and would otherwise repeat "1 $ =" on every row. Same precision
/// rule as [formatExchangeRate]: this is a rate, not a price.
String formatRateQuote(double rate, String toCode) =>
    '${_trimRate(rate)} ${currencySymbolFor(toCode)}';

/// Drops trailing zeros without inventing precision. Written out rather than
/// done with a capturing regex because Dart's [String.replaceFirst] takes the
/// replacement literally — `$1` would land in the output as text.
String _trimRate(double rate) {
  var text = rate.toStringAsFixed(4);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '');
    text = text.replaceAll(RegExp(r'\.$'), '');
  }
  return text;
}
