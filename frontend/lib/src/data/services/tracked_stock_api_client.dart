import '../models/stock_batch.dart';
import '../models/stock_unit.dart';
import '../models/tracked_scan.dart';
import 'api_session.dart';

/// Identified stock over the wire: units, lots, and the scan that resolves
/// either of them.
///
/// [resolveScan] is the only one of these on a hot path, and it is deliberately
/// a *miss* path: the till resolves a plain barcode, a carton barcode and a
/// weighing-scale label from the catalog it already holds, and only asks the
/// server when none of those matched. A shop that sells Coca-Cola never sends
/// this request at all.
class TrackedStockApiClient {
  const TrackedStockApiClient(this._session);

  final PosApiSession _session;

  Future<TrackedScan> resolveScan(String code, {bool activeOnly = true}) async {
    final response = await _session.get(
      'resolve-barcode/',
      query: {'code': code, if (!activeOnly) 'active_only': '0'},
    );
    _session.ensureSuccess(response, 'Barcode resolution failed with status');
    return TrackedScan.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockUnitPage> fetchUnits({
    int? variantId,
    int? productId,
    int? warehouseId,
    String status = '',
    String code = '',
    bool? isIdentified,
    bool? inStock,
    bool forSale = false,
    int page = 1,
  }) async {
    final response = await _session.get(
      'stock-units/',
      query: {
        'page': '$page',
        if (forSale) 'for_sale': '1',
        if (variantId != null) 'variant': '$variantId',
        if (productId != null) 'product': '$productId',
        if (warehouseId != null) 'warehouse': '$warehouseId',
        if (status.isNotEmpty) 'status': status,
        if (code.isNotEmpty) 'code': code,
        if (isIdentified != null)
          'is_identified': isIdentified ? 'true' : 'false',
        if (inStock != null) 'in_stock': inStock ? 'true' : 'false',
      },
    );
    _session.ensureSuccess(response, 'Stock units request failed with status');
    return StockUnitPage.fromJson(_session.decodedBody(response));
  }

  Future<StockUnit> fetchUnit(int unitId) async {
    final response = await _session.get('stock-units/$unitId/');
    _session.ensureSuccess(response, 'Stock unit request failed with status');
    return StockUnit.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<StockAllocationEntry>> fetchUnitHistory(int unitId) async {
    final response = await _session.get('stock-units/$unitId/history/');
    _session.ensureSuccess(response, 'Unit history request failed with status');
    final decoded = _session.decodedBody(response);
    if (decoded is! List<Object?>) {
      return const [];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(StockAllocationEntry.fromJson)
        .toList(growable: false);
  }

  Future<StockUnitLookup> lookupUnit(String code) async {
    final response = await _session.post(
      'stock-units/lookup/',
      body: {'code': code},
    );
    _session.ensureSuccess(response, 'Unit lookup failed with status');
    return StockUnitLookup.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockUnitSummary> fetchUnitSummary({int? warehouseId}) async {
    final response = await _session.get(
      'stock-units/summary/',
      query: {if (warehouseId != null) 'warehouse': '$warehouseId'},
    );
    _session.ensureSuccess(response, 'Unit summary request failed with status');
    return StockUnitSummary.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockUnit> identifyUnit(
    int unitId, {
    required String code,
    String secondaryCode = '',
    String identifierKind = '',
  }) async {
    final response = await _session.post(
      'stock-units/$unitId/identify/',
      body: {
        'code': code,
        if (secondaryCode.isNotEmpty) 'secondary_code': secondaryCode,
        if (identifierKind.isNotEmpty) 'identifier_kind': identifierKind,
      },
    );
    _session.ensureSuccess(response, 'Unit identification failed with status');
    return StockUnit.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockUnit> updateUnit(int unitId, Map<String, Object?> changes) async {
    final response = await _session.patch(
      'stock-units/$unitId/',
      body: changes,
    );
    _session.ensureSuccess(response, 'Unit update failed with status');
    return StockUnit.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockUnit> writeOffUnit(int unitId, {required String reason}) async {
    final response = await _session.post(
      'stock-units/$unitId/write-off/',
      body: {'reason': reason},
    );
    _session.ensureSuccess(response, 'Unit write-off failed with status');
    return StockUnit.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Re-price a shelf's worth of articles in one write.
  ///
  /// [percent] is signed: -15 marks down by fifteen percent. A used-goods
  /// trader marks down every handset over ninety days old at once, and doing
  /// that a row at a time is how it does not get done.
  Future<int> bulkReprice({
    required List<int> unitIds,
    double? price,
    double? percent,
  }) async {
    final response = await _session.post(
      'stock-units/bulk-reprice/',
      body: {
        'ids': unitIds,
        'price': ?price,
        'percent': ?percent,
      },
    );
    _session.ensureSuccess(response, 'Bulk reprice failed with status');
    final body = _session.decodedBody(response);
    if (body is Map<String, Object?>) {
      final updated = body['updated'];
      return updated is num ? updated.toInt() : 0;
    }
    return 0;
  }

  Future<StockBatchPage> fetchBatches({
    int? variantId,
    int? productId,
    int? warehouseId,
    String status = '',
    bool? isExpired,
    bool forSale = false,
    int page = 1,
  }) async {
    final response = await _session.get(
      'stock-batches/',
      query: {
        'page': '$page',
        if (forSale) 'for_sale': '1',
        if (variantId != null) 'variant': '$variantId',
        if (productId != null) 'product': '$productId',
        if (warehouseId != null) 'warehouse': '$warehouseId',
        if (status.isNotEmpty) 'status': status,
        if (isExpired != null) 'is_expired': isExpired ? 'true' : 'false',
      },
    );
    _session.ensureSuccess(
      response,
      'Stock batches request failed with status',
    );
    return StockBatchPage.fromJson(_session.decodedBody(response));
  }

  Future<StockBatch> fetchBatch(int batchId) async {
    final response = await _session.get('stock-batches/$batchId/');
    _session.ensureSuccess(response, 'Stock batch request failed with status');
    return StockBatch.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<StockAllocationEntry>> fetchBatchHistory(int batchId) async {
    final response = await _session.get('stock-batches/$batchId/history/');
    _session.ensureSuccess(response, 'Lot history request failed with status');
    final decoded = _session.decodedBody(response);
    if (decoded is! List<Object?>) {
      return const [];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(StockAllocationEntry.fromJson)
        .toList(growable: false);
  }

  Future<StockBatch> setBatchQuarantine(
    int batchId, {
    required bool locked,
  }) async {
    final path = locked
        ? 'stock-batches/$batchId/quarantine/'
        : 'stock-batches/$batchId/release-quarantine/';
    final response = await _session.post(path, body: const {});
    _session.ensureSuccess(response, 'Lot quarantine failed with status');
    return StockBatch.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<StockBatchPage> fetchExpiryWatchlist({int days = 30}) async {
    final response = await _session.get(
      'stock-batches/expiry-watchlist/',
      query: {'days': '$days'},
    );
    _session.ensureSuccess(response, 'Expiry watchlist failed with status');
    return StockBatchPage.fromJson(_session.decodedBody(response));
  }
}
