import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/service_country_detail.dart';
import '../../../data/models/service_kinds.dart';
import '../../../data/models/services_directory.dart';
import '../../../data/repositories/integrations_repository.dart';
import '../direct_services/country_search.dart';

/// What «كروت دفتر»' direct services know about the world, held for the length
/// of the shift and shared by the airtime pane and every bill flow.
///
/// The directory (countries, calling codes, counts) is read once and kept; a
/// country's networks and providers are read when it is picked and kept too.
/// Flags ship with the app (`assets/flags/`) and are never asked for. A failed
/// read keeps what is held — stale beats blank — and only something that never
/// loaded shows its error.
class ServicesCatalog extends ChangeNotifier {
  ServicesCatalog({required IntegrationsRepository repository})
    : _repository = repository;

  final IntegrationsRepository _repository;

  bool _disposed = false;

  // --- the directory ---------------------------------------------------------

  ServicesDirectory? _directory;
  DateTime? _directoryReadAt;
  Future<void>? _directoryInFlight;
  bool _directoryFailed = false;
  final Map<String, CountrySearch> _searches = {};

  /// Null until the first read lands.
  ServicesDirectory? get directory => _directory;

  /// The relay is buying from its test supplier — fake money, nothing really
  /// sent — as the directory says, or the country [country] says when it is
  /// asked about one.
  bool isTestMode({String? country}) =>
      _directory?.testMode == true ||
      (country != null && detailOf(country)?.testMode == true);

  /// The first read is on its way.
  bool get isLoadingDirectory =>
      _directoryInFlight != null && _directory == null;

  /// Nothing to show and the last read failed.
  bool get hasDirectoryError =>
      _directoryFailed && _directory == null && _directoryInFlight == null;

  /// Reads the directory unless one is held or on its way.
  Future<void> ensureLoaded() {
    if (_directory != null) {
      return Future.value();
    }
    return reload();
  }

  /// How long a directory read is trusted before the screen that opens asks
  /// again: prices and networks move, and a till can stay open for days.
  static const Duration directoryFreshFor = Duration(minutes: 10);

  /// Reads the directory unless a fresh one is held: what a screen does when
  /// it opens. What is held stays on screen until the new answer lands.
  Future<void> ensureFresh({Duration maxAge = directoryFreshFor}) {
    final at = _directoryReadAt;
    if (_directory != null &&
        at != null &&
        DateTime.now().difference(at) < maxAge) {
      return Future.value();
    }
    return _directory == null ? ensureLoaded() : reload();
  }

  /// Forgets everything held — the directory, every country read, and what was
  /// searched in them — so the next screen to open reads it all again.
  void clear() {
    _directory = null;
    _directoryReadAt = null;
    _directoryFailed = false;
    _details.clear();
    _detailsFailed.clear();
    _searches.clear();
    _notify();
  }

  /// Reads the directory again; what is held stays until the answer lands.
  Future<void> reload() {
    final inFlight = _directoryInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    late final Future<void> future;
    future = _readDirectory().whenComplete(() {
      if (identical(_directoryInFlight, future)) {
        _directoryInFlight = null;
        _notify();
      }
    });
    _directoryInFlight = future;
    _directoryFailed = false;
    _notify();
    return future;
  }

  Future<void> _readDirectory() async {
    final result = await _repository.loadServicesDirectory();
    if (_disposed) {
      return;
    }
    switch (result) {
      case Ok<ServicesDirectory>(:final value):
        // The directory says when what it lists moved. Countries read under an
        // older edition are not trusted: they are read again as they are used.
        final old = _directory;
        if (old != null &&
            value.version.isNotEmpty &&
            old.version != value.version) {
          _details.clear();
          _detailsFailed.clear();
        }
        _directory = value;
        _directoryReadAt = DateTime.now();
        _directoryFailed = false;
        _searches.clear();
      case Error<ServicesDirectory>():
        _directoryFailed = true;
    }
  }

  /// The search over the countries airtime can be sent to.
  CountrySearch? get airtimeSearch =>
      _searchFor('airtime', (directory) => directory.airtimeCountries);

  /// The search over the countries that have a provider of [type].
  CountrySearch? billSearch(BillType type) => _searchFor(
    'bill:${billTypeToJson(type)}',
    (directory) => directory.billCountries(type),
  );

  CountrySearch? _searchFor(
    String key,
    List<ServiceCountry> Function(ServicesDirectory directory) pick,
  ) {
    final directory = _directory;
    if (directory == null) {
      return null;
    }
    // Countries the services do not reach are named only where airtime is
    // asked for: «السودان» must never answer "no results" there.
    return _searches.putIfAbsent(
      key,
      () => CountrySearch(
        countries: pick(directory),
        unsupported: key == 'airtime' ? directory.unsupported : const [],
        popular: directory.popular,
      ),
    );
  }

  // --- one country -----------------------------------------------------------

  final Map<String, ServiceCountryDetail> _details = {};
  final Map<String, Future<ServiceCountryDetail?>> _detailsInFlight = {};
  final Set<String> _detailsFailed = {};

  ServiceCountryDetail? detailOf(String code) => _details[code.toUpperCase()];

  bool isLoadingDetail(String code) =>
      _detailsInFlight.containsKey(code.toUpperCase());

  bool hasDetailError(String code) {
    final key = code.toUpperCase();
    return _detailsFailed.contains(key) &&
        !_details.containsKey(key) &&
        !_detailsInFlight.containsKey(key);
  }

  /// A country's networks and providers: held, or read now. Null when it
  /// cannot be read.
  Future<ServiceCountryDetail?> loadDetail(String code, {bool force = false}) {
    final key = code.toUpperCase();
    final held = _details[key];
    if (held != null && !force) {
      return Future.value(held);
    }
    final inFlight = _detailsInFlight[key];
    if (inFlight != null) {
      return inFlight;
    }
    late final Future<ServiceCountryDetail?> future;
    future = _readDetail(key).whenComplete(() {
      if (identical(_detailsInFlight[key], future)) {
        _detailsInFlight.remove(key);
        _notify();
      }
    });
    _detailsInFlight[key] = future;
    _detailsFailed.remove(key);
    _notify();
    return future;
  }

  Future<ServiceCountryDetail?> _readDetail(String code) async {
    final result = await _repository.loadServiceCountry(code);
    if (_disposed) {
      return null;
    }
    switch (result) {
      case Ok<ServiceCountryDetail>(:final value) when !value.available:
        // The shop stopped being able to sell between the directory and this
        // answer. There is nothing to show for the country: read the directory
        // again, so the screen says why instead of offering an empty country.
        _detailsFailed.add(code);
        unawaited(reload());
        return null;
      case Ok<ServiceCountryDetail>(:final value):
        // A server that forgets to name the country still answered for it.
        final detail = value.country.code.isEmpty
            ? ServiceCountryDetail(
                country:
                    _directory?.country(code) ?? ServiceCountry(code: code),
                operators: value.operators,
                billers: value.billers,
                testMode: value.testMode,
              )
            : value;
        _details[code] = detail;
        _detailsFailed.remove(code);
        return detail;
      case Error<ServiceCountryDetail>():
        _detailsFailed.add(code);
        return null;
    }
  }

  /// Reads several countries in the background, so their providers' counts
  /// are on screen by the time the cashier looks for them.
  void prefetchDetails(Iterable<String> codes) {
    for (final code in codes) {
      final key = code.toUpperCase();
      if (!_details.containsKey(key) &&
          !_detailsInFlight.containsKey(key) &&
          !_detailsFailed.contains(key)) {
        unawaited(loadDetail(key));
      }
    }
  }

  void _notify() {
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
