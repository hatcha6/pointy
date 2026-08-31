import '../models/exchange_rate.dart';
import 'api_session.dart';

class FxApiClient {
  const FxApiClient(this._session);

  final PosApiSession _session;

  /// The rates the shop would price at right now, with their provenance.
  Future<CurrentRates> fetchCurrentRates() async {
    final response = await _session.get('exchange-rates/current/');
    _session.ensureSuccess(
      response,
      'Exchange rates request failed with status',
    );
    return CurrentRates.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<Currency>> fetchCurrencies() async {
    final response = await _session.get(
      'currencies/',
      query: {'page_size': '100'},
    );
    _session.ensureSuccess(response, 'Currencies request failed with status');
    final body = _session.decodedBody(response);
    final rows = body is Map<String, Object?>
        ? (body['results'] as List<Object?>? ?? const <Object?>[])
        : (body as List<Object?>? ?? const <Object?>[]);
    return rows
        .whereType<Map<String, Object?>>()
        .map(Currency.fromJson)
        .toList();
  }

  /// The rate history — what the shop knew, and when.
  Future<List<ExchangeRate>> fetchRateHistory({String? fromCode}) async {
    final response = await _session.get(
      'exchange-rates/',
      query: {
        'page_size': '100',
        'ordering': '-effective_at',
        if (fromCode != null && fromCode.isNotEmpty) 'from_currency': fromCode,
      },
    );
    _session.ensureSuccess(response, 'Rate history request failed with status');
    final body = _session.decodedBody(response);
    final rows = body is Map<String, Object?>
        ? (body['results'] as List<Object?>? ?? const <Object?>[])
        : (body as List<Object?>? ?? const <Object?>[]);
    return rows
        .whereType<Map<String, Object?>>()
        .map(ExchangeRate.fromJson)
        .toList();
  }

  Future<ExchangeRate> recordManualRate(ManualRateDraft draft) async {
    final response = await _session.post(
      'exchange-rates/manual/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Manual rate failed with status');
    return ExchangeRate.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Pull from the relay now rather than waiting for the hourly sync.
  Future<Map<String, Object?>> syncNow() async {
    final response = await _session.post('exchange-rates/sync/');
    _session.ensureSuccess(response, 'Rate sync failed with status');
    return _session.decodedBody(response) as Map<String, Object?>;
  }

  /// What a rate move would do to the catalogue. Writes nothing.
  Future<RepricePreview> fetchRepricePreview() async {
    final response = await _session.get('repricing/preview/');
    _session.ensureSuccess(response, 'Reprice preview failed with status');
    return RepricePreview.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Apply only the rows the owner approved, at the rate they were shown.
  Future<int> applyReprice(
    List<PriceProposal> approved, {
    DateTime? resolvedAt,
  }) async {
    final response = await _session.post(
      'repricing/apply/',
      body: <String, Object?>{
        'targets': approved.map((p) => p.toTargetJson()).toList(),
        if (resolvedAt != null)
          'resolved_at': resolvedAt.toUtc().toIso8601String(),
      },
    );
    _session.ensureSuccess(response, 'Reprice apply failed with status');
    final body = _session.decodedBody(response) as Map<String, Object?>;
    return int.tryParse(body['repriced']?.toString() ?? '') ?? 0;
  }
}
