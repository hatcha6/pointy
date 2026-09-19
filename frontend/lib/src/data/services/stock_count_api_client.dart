import '../models/stock_count.dart';
import '../models/stock_count_draft.dart';
import '../models/stock_count_line.dart';
import 'api_session.dart';

class StockCountApiClient {
  const StockCountApiClient(this._session);

  final PosApiSession _session;

  Future<StockCount> startCount(StockCountStartDraft draft) async {
    final response = await _session.post(
      'stock-counts/start/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Stock count start failed with status');
    return StockCount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockCount?> fetchCurrentCount() async {
    final response = await _session.get('stock-counts/current/');
    if (response.statusCode == 204) {
      return null;
    }
    _session.ensureSuccess(
      response,
      'Current stock count request failed with status',
    );
    return StockCount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockCountPage> fetchCounts({String? status, int page = 1}) async {
    final response = await _session.get(
      'stock-counts/',
      query: {
        'page': '$page',
        'ordering': '-created_at',
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    _session.ensureSuccess(response, 'Stock counts request failed with status');
    return StockCountPage.fromJson(_session.decodedBody(response));
  }

  Future<StockCount> fetchCount(int countId) async {
    final response = await _session.get('stock-counts/$countId/');
    _session.ensureSuccess(response, 'Stock count request failed with status');
    return StockCount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockCountLine> countLine(
    int countId,
    StockCountLineDraft draft,
  ) async {
    final response = await _session.post(
      'stock-counts/$countId/count/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Stock count entry failed with status');
    return StockCountLine.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Returns every differing line (paginated server-side, accumulated here);
  /// the set is bounded by what was counted, so this stays small in practice.
  Future<List<StockCountLine>> fetchReconciliation(int countId) async {
    final lines = <StockCountLine>[];
    var page = 1;
    while (true) {
      final response = await _session.get(
        'stock-counts/$countId/reconciliation/',
        query: {'page': '$page'},
      );
      _session.ensureSuccess(
        response,
        'Stock count reconciliation request failed with status',
      );
      final decoded = _session.decodedBody(response);
      lines.addAll(resultsFromDecoded(decoded).map(StockCountLine.fromJson));
      final hasMore =
          decoded is Map<String, Object?> && decoded['next'] != null;
      if (!hasMore) {
        break;
      }
      page += 1;
    }
    return lines;
  }

  Future<StockCount> applyCount(
    int countId, {
    required String idempotencyKey,
  }) async {
    final response = await _session.post(
      'stock-counts/$countId/apply/',
      idempotencyKey: idempotencyKey,
    );
    _session.ensureSuccess(response, 'Stock count apply failed with status');
    return StockCount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// One identifier, read off the shelf (§6.6).
  ///
  /// [variantId] is for the one case the identifier cannot answer by itself:
  /// a code nothing in the shop has ever seen. There is no way to know what
  /// product that is, so the counter says.
  Future<StockCountScanResult> scan(
    int countId,
    String code, {
    int? variantId,
  }) async {
    final response = await _session.post(
      'stock-counts/$countId/scan/',
      body: {'code': code, 'variant': ?variantId},
    );
    _session.ensureSuccess(response, 'Stock count scan failed with status');
    return StockCountScanResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockCountScanReconciliation> fetchScanReconciliation(
    int countId,
  ) async {
    final response = await _session.get(
      'stock-counts/$countId/scan-reconciliation/',
    );
    _session.ensureSuccess(
      response,
      'Stock count scan reconciliation failed with status',
    );
    return StockCountScanReconciliation.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockCount> cancelCount(int countId) async {
    final response = await _session.post('stock-counts/$countId/cancel/');
    _session.ensureSuccess(response, 'Stock count cancel failed with status');
    return StockCount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
