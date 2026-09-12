import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/exchange_rate.dart';
import '../../../data/repositories/fx_repository.dart';

/// The exchange-rate band at the top of the dashboard.
///
/// Three decisions carry it.
///
/// **It is not gated on `fx_enabled`.** That switch exists to stop a
/// single-currency shop being *asked* which currency something is priced in —
/// the product form, the purchase order. This band asks nothing: it reports the
/// parallel-market rate, which in Libya is the number every shopkeeper already
/// checks on their phone whether or not they ever buy in dollars. What it is
/// gated on is having an actual rate to show, so a shop whose relay has never
/// delivered sees no band rather than an empty one.
///
/// **Nothing here is ever invented.** No rate is seeded at install — the only
/// built-in rate in the whole system is a currency against itself — so every
/// number in this band was published or typed. A currency with no resolvable
/// rate is dropped from the band instead of being shown at zero.
///
/// **The trend loads after the rates, and never blocks them.** The band paints
/// as soon as the current rates land; the short history behind each sparkline
/// arrives separately and simply does not appear if it fails. One request per
/// tracked currency, once per session — a rate that moves a few times a day
/// does not deserve a poll.
class DashboardFxViewModel extends ChangeNotifier {
  DashboardFxViewModel(this._repository);

  final FxRepository _repository;

  /// What the band tracks, in the order a Libyan shop cares about them:
  /// the dollar imports are priced in first, then the two European currencies.
  /// The backend serves every enabled currency; showing all nine would make a
  /// glance into a table.
  static const List<String> trackedCodes = <String>['USD', 'EUR', 'GBP'];

  /// Points behind one sparkline. Enough to read a direction over a few days,
  /// few enough that the request stays a rounding error.
  static const int trendPoints = 24;

  CurrentRates _rates = CurrentRates.empty;
  Map<String, List<double>> _trends = const <String, List<double>>{};
  bool _isLoading = false;
  bool _hasLoaded = false;

  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  CurrentRates get rates => _rates;

  /// The rates to draw, in [trackedCodes] order, skipping any the shop cannot
  /// resolve — including its own currency, which the backend never quotes.
  List<ResolvedRate> get tracked {
    final resolved = <ResolvedRate>[];
    for (final code in trackedCodes) {
      final rate = _rates.rateFor(code);
      if (rate != null) {
        resolved.add(rate);
      }
    }
    return List<ResolvedRate>.unmodifiable(resolved);
  }

  /// Whether the band appears at all. No rates is a legitimate answer, and a
  /// dashboard with a hole labelled "exchange rates" is worse than one without.
  bool get isVisible => tracked.isNotEmpty;

  /// Recent rates for [code], oldest first, ending at the one on show. Empty
  /// until the history lands, and empty forever if it never does.
  List<double> trendFor(String code) =>
      _trends[code.trim().toUpperCase()] ?? const <double>[];

  Future<void> load() async {
    if (_isLoading) {
      return;
    }
    _isLoading = true;
    notifyListeners();

    final result = await _repository.loadCurrentRates();
    if (result case Ok<CurrentRates>(value: final loaded)) {
      _rates = loaded;
    }

    _isLoading = false;
    _hasLoaded = true;
    notifyListeners();

    if (isVisible) {
      unawaited(_loadTrends());
    }
  }

  /// Pull-to-refresh and the dashboard's own refresh button land here.
  Future<void> refresh() => load();

  Future<void> _loadTrends() async {
    final wanted = tracked;
    final histories = await Future.wait(
      wanted.map(
        (rate) => _repository.loadRateHistory(
          fromCode: rate.fromCode,
          pageSize: trendPoints,
        ),
      ),
    );

    final trends = <String, List<double>>{};
    for (var index = 0; index < wanted.length; index += 1) {
      if (histories[index] case Ok<List<ExchangeRate>>(value: final rows)) {
        final series = _seriesFor(wanted[index], rows);
        if (series.length >= 2) {
          trends[wanted[index].fromCode] = series;
        }
      }
    }
    _trends = Map<String, List<double>>.unmodifiable(trends);
    notifyListeners();
  }

  /// The stored rows that produced [rate], oldest first.
  ///
  /// Matched on the settlement series actually resolved — not the one the shop
  /// asked for — because a band drawing a cash trend under a bank rate would be
  /// comparing two different prices. An inverted rate is skipped outright: the
  /// stored rows quote the other direction, and flipping each one to fake a
  /// trend is exactly the kind of quiet arithmetic this feature avoids.
  List<double> _seriesFor(ResolvedRate rate, List<ExchangeRate> rows) {
    if (rate.inverted) {
      return const <double>[];
    }
    final matching =
        rows
            .where(
              (row) =>
                  row.fromCode == rate.fromCode &&
                  row.toCode == rate.toCode &&
                  row.instrument == rate.instrument &&
                  row.bankCode == rate.bankCode &&
                  row.rate > 0,
            )
            .toList()
          // The API orders newest first; a sparkline reads left to right.
          ..sort((a, b) {
            final left = a.effectiveAt;
            final right = b.effectiveAt;
            if (left == null || right == null) {
              return 0;
            }
            return left.compareTo(right);
          });
    return List<double>.unmodifiable(matching.map((row) => row.rate));
  }
}
