import '../models/bulk_price_preview.dart';
import 'api_session.dart';

/// `bulk-price-changes/` — the rule-driven bulk price editor's endpoints.
class BulkPriceApiClient {
  const BulkPriceApiClient(this._session);

  final PosApiSession _session;

  Future<BulkPriceOptions> fetchOptions() async {
    final response = await _session.get('bulk-price-changes/options/');
    _session.throwApiException(response, 'Bulk price options failed');
    return BulkPriceOptions.fromJson(_map(_session.decodedBody(response)));
  }

  Future<BulkPricePreview> preview({
    required Map<String, Object?> spec,
    required BulkPricePreviewView view,
    int offset = 0,
    int limit = 50,
  }) async {
    final response = await _session.post(
      'bulk-price-changes/preview/',
      body: {...spec, 'view': view.apiValue, 'offset': offset, 'limit': limit},
    );
    _session.throwApiException(response, 'Bulk price preview failed');
    return BulkPricePreview.fromJson(_map(_session.decodedBody(response)));
  }

  /// Applies [spec] only if it still yields [fingerprint]; otherwise throws
  /// [BulkPriceException] with [BulkPriceFailure.stale].
  Future<BulkPriceChangeRecord> apply({
    required Map<String, Object?> spec,
    required String fingerprint,
  }) async {
    final response = await _session.post(
      'bulk-price-changes/',
      body: {...spec, 'fingerprint': fingerprint},
    );
    if (response.statusCode == 409) {
      throw const BulkPriceException(BulkPriceFailure.stale);
    }
    if (response.statusCode == 400 &&
        '${_session.decodedBodyOrNull(response)}'.contains('change no price')) {
      throw const BulkPriceException(BulkPriceFailure.nothingToApply);
    }
    _session.throwApiException(response, 'Bulk price apply failed');
    return BulkPriceChangeRecord.fromJson(_map(_session.decodedBody(response)));
  }

  Future<List<BulkPriceChangeRecord>> fetchHistory() async {
    final response = await _session.get('bulk-price-changes/');
    _session.throwApiException(response, 'Bulk price history failed');
    final body = _session.decodedBody(response);
    final results = body is Map ? body['results'] : body;
    return [
      for (final item in (results as List?) ?? const [])
        if (item is Map) BulkPriceChangeRecord.fromJson(item.cast()),
    ];
  }

  Future<BulkPriceChangeRecord> revert(int id) async {
    final response = await _session.post('bulk-price-changes/$id/revert/');
    if (response.statusCode == 409) {
      throw const BulkPriceException(BulkPriceFailure.alreadyReverted);
    }
    _session.throwApiException(response, 'Bulk price revert failed');
    return BulkPriceChangeRecord.fromJson(_map(_session.decodedBody(response)));
  }

  static Map<String, dynamic> _map(Object? body) =>
      body is Map ? body.cast<String, dynamic>() : const {};
}
