import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/result.dart';
import '../../core/storage/app_key_value_store.dart';
import '../../data/models/exchange_rate.dart';
import '../../data/repositories/fx_repository.dart';
import 'calculator_number.dart';

/// A currency the converter can offer: the shop's own, or one with a rate.
@immutable
class ConverterCurrency {
  const ConverterCurrency({
    required this.code,
    required this.nameAr,
    required this.nameEn,
    required this.symbol,
    required this.decimals,
  });

  final String code;
  final String nameAr;
  final String nameEn;
  final String symbol;

  /// Minor units: 3 for the dinar, 2 for the dollar. A converted amount is
  /// shown and copied to exactly this many places.
  final int decimals;

  String get name => nameAr.isNotEmpty ? nameAr : nameEn;
}

/// One foreign currency's rate into the shop's base currency, as resolved by
/// the backend from the Fulus feed (or a rate the owner typed).
@immutable
class ConverterRate {
  const ConverterRate({
    required this.code,
    required this.valueInBase,
    required this.ageHours,
    required this.isStale,
    required this.isSubstituted,
    required this.source,
    required this.instrument,
  });

  final String code;

  /// What one unit of [code] is worth in the base currency, exactly as the
  /// backend sent it.
  final CalculatorNumber valueInBase;
  final double ageHours;
  final bool isStale;

  /// Priced off another settlement series because the shop's had no rate.
  final bool isSubstituted;
  final RateSource source;
  final SettlementInstrument instrument;
}

/// Everything the converter knows, as of [loadedAt].
@immutable
class ConverterRates {
  const ConverterRates({
    required this.baseCode,
    required this.currencies,
    required this.rates,
    required this.instrument,
    required this.loadedAt,
  });

  final String baseCode;

  /// The base currency first, then every foreign one that has a rate, in the
  /// shop's display order. A currency without a rate is not offered: it
  /// could only ever say "unavailable".
  final List<ConverterCurrency> currencies;
  final Map<String, ConverterRate> rates;
  final SettlementInstrument instrument;
  final DateTime loadedAt;

  bool get hasForeign => currencies.any((c) => c.code != baseCode);

  ConverterCurrency? currency(String code) {
    for (final currency in currencies) {
      if (currency.code == code) {
        return currency;
      }
    }
    return null;
  }

  /// [amount] of [from] in [to], exactly — through the base currency, the
  /// way every Fulus rate is quoted (USD→EUR is USD→LYD→EUR). Null when
  /// either side has no rate.
  CalculatorNumber? convert(CalculatorNumber amount, String from, String to) {
    if (from == to) {
      return amount;
    }
    final inBase = from == baseCode
        ? amount
        : _times(amount, rates[from]?.valueInBase);
    if (inBase == null) {
      return null;
    }
    if (to == baseCode) {
      return inBase;
    }
    final target = rates[to]?.valueInBase;
    if (target == null || target.isZero) {
      return null;
    }
    return inBase / target;
  }

  static CalculatorNumber? _times(CalculatorNumber a, CalculatorNumber? b) =>
      b == null ? null : a * b;

  /// The rates a conversion between [a] and [b] rests on (the base currency
  /// needs none).
  List<ConverterRate> ratesFor(String a, String b) => [
    for (final code in {a, b})
      if (code != baseCode && rates[code] != null) rates[code]!,
  ];

  /// Builds the snapshot from the backend's two answers. Every rate is read
  /// from its decimal text, so 7.188 is 7188/1000 and not a binary double.
  factory ConverterRates.from(
    CurrentRates current,
    List<Currency> registry, {
    required DateTime loadedAt,
  }) {
    final rates = <String, ConverterRate>{};
    for (final rate in current.rates) {
      final value = _exact(rate.rate);
      if (rate.toCode != current.baseCode || value == null || value.isZero) {
        continue;
      }
      rates[rate.fromCode] = ConverterRate(
        code: rate.fromCode,
        valueInBase: value,
        ageHours: rate.ageHours,
        isStale: rate.isStale,
        isSubstituted: rate.isSubstituted,
        source: rate.source,
        instrument: rate.instrument,
      );
    }
    final ordered = [...registry]
      ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    ConverterCurrency toCurrency(Currency c) => ConverterCurrency(
      code: c.code,
      nameAr: c.nameAr,
      nameEn: c.nameEn,
      symbol: c.symbol,
      decimals: c.decimals,
    );
    final base = ordered.where((c) => c.code == current.baseCode);
    return ConverterRates(
      baseCode: current.baseCode,
      currencies: [
        if (base.isNotEmpty)
          toCurrency(base.first)
        else
          ConverterCurrency(
            code: current.baseCode,
            nameAr: current.baseCode,
            nameEn: current.baseCode,
            symbol: current.baseCode,
            decimals: 3,
          ),
        for (final currency in ordered)
          if (currency.code != current.baseCode &&
              rates.containsKey(currency.code))
            toCurrency(currency),
      ],
      rates: rates,
      instrument: current.instrument,
      loadedAt: loadedAt,
    );
  }

  static CalculatorNumber? _exact(double rate) {
    if (!rate.isFinite || rate <= 0) {
      return null;
    }
    return CalculatorNumber.tryParse(rate.toString()) ??
        CalculatorNumber.tryParse(rate.toStringAsFixed(10));
  }
}

typedef ConverterRatesLoader = Future<Result<ConverterRates>> Function();

/// The converter's source: the shop's current rates and its currency list,
/// fetched together.
ConverterRatesLoader fxConverterRatesLoader(
  FxRepository repository, {
  DateTime Function() clock = DateTime.now,
}) {
  return () async {
    // Both requests in flight together.
    final ratesRequest = repository.loadCurrentRates();
    final currenciesRequest = repository.loadCurrencies();
    final current = await ratesRequest;
    final currencies = await currenciesRequest;
    return switch ((current, currencies)) {
      (Ok(value: final rates), Ok(value: final registry)) => Ok(
        ConverterRates.from(rates, registry, loadedAt: clock()),
      ),
      (Error(:final exception), _) => Error(exception),
      (_, Error(:final exception)) => Error(exception),
    };
  };
}

enum ConverterStatus { idle, loading, ready, failed }

/// The calculator's Convert mode, modelled on Calculator.app's (checked by
/// using it, and by REA against its binary):
///
/// - Two rows, each with a currency. One row is the input: the calculator
///   types into it, the other shows the converted amount, live.
/// - ⇅ (or Tab) swaps which row is the input; the typed number stays and
///   now means the other currency (240 USD → 240 EUR).
/// - Tapping the result row makes it the input, carrying its value.
/// - Picking a currency keeps the number; the other row's currency cannot
///   be picked (Apple greys it out).
/// - The last pair, the input side and the recently used currencies are
///   remembered (Apple's UnitConversionRestoreState / RecentUnits).
/// - Rates are refreshed when Convert opens if they are older than
///   [refreshAfter]. Old rates still convert (Apple's
///   AllowStaleCurrencyConversions) but are flagged, with their age; a failed
///   refresh keeps the last good rates and says so.
class CurrencyConverter extends ChangeNotifier {
  CurrencyConverter({
    this.loader,
    this.clock = DateTime.now,
    this.refreshAfter = const Duration(minutes: 10),
    this.recentLimit = 4,
  }) {
    unawaited(_restore());
  }

  static const String storageKey = 'calculator.converter.v1';

  /// Null when the signed-in user may not read rates (or nobody is signed
  /// in): the Convert toggle is not offered at all.
  ConverterRatesLoader? loader;
  final DateTime Function() clock;
  final Duration refreshAfter;
  final int recentLimit;

  bool _enabled = false;
  ConverterStatus _status = ConverterStatus.idle;
  ConverterRates? _rates;
  bool _lastRefreshFailed = false;
  String? _topCode;
  String? _bottomCode;
  bool _inputIsTop = true;
  List<String> _recents = const [];
  bool _disposed = false;
  Future<void>? _inFlight;

  bool get isAvailable => loader != null;
  bool get enabled => _enabled && isAvailable;
  ConverterStatus get status => _status;
  ConverterRates? get rates => _rates;

  /// The latest refresh failed; [rates] (if any) are the last good ones.
  bool get lastRefreshFailed => _lastRefreshFailed;
  bool get inputIsTop => _inputIsTop;
  List<String> get recents => List.unmodifiable(_recents);

  /// Whether conversions can be shown: rates with at least one foreign
  /// currency, and a valid pair.
  bool get isReady => _rates?.hasForeign == true && _pairValid;

  String? get topCode => _topCode;
  String? get bottomCode => _bottomCode;
  String? get inputCode => _inputIsTop ? _topCode : _bottomCode;
  String? get outputCode => _inputIsTop ? _bottomCode : _topCode;

  ConverterCurrency? currency(String? code) =>
      code == null ? null : _rates?.currency(code);

  bool get _pairValid =>
      _topCode != null &&
      _bottomCode != null &&
      _topCode != _bottomCode &&
      _rates?.currency(_topCode!) != null &&
      _rates?.currency(_bottomCode!) != null;

  void setEnabled(bool value) {
    if (value == _enabled) {
      return;
    }
    _enabled = value;
    _persist();
    _changed();
    if (value) {
      unawaited(refresh());
    }
  }

  void toggle() => setEnabled(!_enabled);

  /// Fetches rates unless the last good ones are recent enough. [force]
  /// always fetches (the refresh button). Concurrent calls share one fetch.
  Future<void> refresh({bool force = false}) {
    final load = loader;
    if (load == null) {
      return Future.value();
    }
    final current = _rates;
    if (!force &&
        current != null &&
        !_lastRefreshFailed &&
        clock().difference(current.loadedAt) < refreshAfter) {
      return Future.value();
    }
    return _inFlight ??= _load(load).whenComplete(() => _inFlight = null);
  }

  Future<void> _load(ConverterRatesLoader load) async {
    _status = ConverterStatus.loading;
    _changed();
    final result = await load();
    if (_disposed) {
      return;
    }
    switch (result) {
      case Ok(:final value):
        _rates = value;
        _lastRefreshFailed = false;
        _status = ConverterStatus.ready;
        _settlePair();
      case Error():
        _lastRefreshFailed = true;
        _status = _rates == null
            ? ConverterStatus.failed
            : ConverterStatus.ready;
    }
    _changed();
  }

  /// Signed out, or the user changed: forget the shop's rates (the pair and
  /// recents are this machine's and stay).
  void reset({ConverterRatesLoader? loader}) {
    this.loader = loader;
    _rates = null;
    _status = ConverterStatus.idle;
    _lastRefreshFailed = false;
    _inFlight = null;
    _changed();
  }

  /// ⇅: the other row becomes the input. The typed number is kept.
  void swap() {
    _inputIsTop = !_inputIsTop;
    _persist();
    _changed();
  }

  /// Makes [top]'s row the input (a tap on it). Returns whether it changed.
  bool focusRow({required bool top}) {
    if (_inputIsTop == top) {
      return false;
    }
    _inputIsTop = top;
    _persist();
    _changed();
    return true;
  }

  /// Whether [code] may be picked for the [top] row: not the other row's.
  bool canPick(String code, {required bool top}) =>
      code != (top ? _bottomCode : _topCode);

  /// Sets [top]'s row to [code]. Refuses the other row's currency.
  bool pick(String code, {required bool top}) {
    if (!canPick(code, top: top) || _rates?.currency(code) == null) {
      return false;
    }
    if (top) {
      _topCode = code;
    } else {
      _bottomCode = code;
    }
    _recents = [
      code,
      ..._recents.where((c) => c != code),
    ].take(recentLimit).toList();
    _persist();
    _changed();
    return true;
  }

  /// [amount] in the input currency, converted to the output currency —
  /// exact; round with [ConverterCurrency.decimals] to show it.
  CalculatorNumber? convert(CalculatorNumber? amount) {
    final rates = _rates;
    if (amount == null || rates == null || !_pairValid) {
      return null;
    }
    return rates.convert(amount, inputCode!, outputCode!);
  }

  /// The converted amount as shown: rounded to the output currency.
  CalculatorNumber? convertRounded(CalculatorNumber? amount) {
    final value = convert(amount);
    final decimals = currency(outputCode)?.decimals;
    if (value == null || decimals == null) {
      return null;
    }
    return value.roundedTo(decimals);
  }

  /// The rates behind the current pair.
  List<ConverterRate> get pairRates {
    final rates = _rates;
    if (rates == null || !_pairValid) {
      return const [];
    }
    return rates.ratesFor(_topCode!, _bottomCode!);
  }

  /// A valid pair after rates arrive: what was remembered if still offered,
  /// else the dollar (the currency asked about most) against the shop's own.
  void _settlePair() {
    final rates = _rates;
    if (rates == null || !rates.hasForeign) {
      return;
    }
    bool offered(String? code) => code != null && rates.currency(code) != null;
    final foreign = rates.currencies.where((c) => c.code != rates.baseCode);
    final defaultForeign = rates.currency('USD') != null
        ? 'USD'
        : foreign.first.code;
    var top = offered(_topCode) ? _topCode! : defaultForeign;
    var bottom = offered(_bottomCode) ? _bottomCode! : rates.baseCode;
    if (top == bottom) {
      bottom = top == rates.baseCode ? defaultForeign : rates.baseCode;
    }
    _topCode = top;
    _bottomCode = bottom;
    _recents = _recents.where(offered).toList();
  }

  Future<void> _restore() async {
    try {
      final store = await AppKeyValueStore.instance();
      final raw = await store.getString(storageKey);
      if (raw == null || _disposed) {
        return;
      }
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) {
        return;
      }
      // Only fill what nobody set while the store was opening.
      _topCode ??= json['top'] as String?;
      _bottomCode ??= json['bottom'] as String?;
      _inputIsTop = json['input_top'] as bool? ?? _inputIsTop;
      if (_recents.isEmpty) {
        _recents = (json['recents'] as List<Object?>? ?? const [])
            .whereType<String>()
            .take(recentLimit)
            .toList();
      }
      if (json['on'] == true && !_enabled) {
        _enabled = true;
      }
      _settlePair();
      _changed();
    } on Object {
      // A converter that forgets its pair starts at USD → the shop's own.
    }
  }

  void _persist() {
    final snapshot = jsonEncode({
      'on': _enabled,
      'top': _topCode,
      'bottom': _bottomCode,
      'input_top': _inputIsTop,
      'recents': _recents,
    });
    unawaited(() async {
      try {
        final store = await AppKeyValueStore.instance();
        await store.setString(storageKey, snapshot);
      } on Object {
        // Remembering the pair is a convenience; never a failure.
      }
    }());
  }

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
