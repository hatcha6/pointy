import '../models/consignment.dart';
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
      body: {'ids': unitIds, 'price': ?price, 'percent': ?percent},
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

  /// Lots expiring soon, each with its markdown suggestion (§6.8.1's quieter
  /// sibling). Returns the raw decoded body as well so the caller can read the
  /// per-row ``markdown`` block the page serializer adds.
  Future<(StockBatchPage, Map<int, ExpiryMarkdownSuggestion>)>
  fetchExpiryWatchlist({int days = 30}) async {
    final response = await _session.get(
      'stock-batches/expiry-watchlist/',
      query: {'days': '$days'},
    );
    _session.ensureSuccess(response, 'Expiry watchlist failed with status');
    final decoded = _session.decodedBody(response);
    final page = StockBatchPage.fromJson(decoded);
    final suggestions = <int, ExpiryMarkdownSuggestion>{};
    for (final row in resultsFromDecoded(decoded)) {
      final markdown = row['markdown'];
      final id = (row['id'] as num?)?.toInt();
      if (id != null && markdown is Map<String, Object?>) {
        suggestions[id] = ExpiryMarkdownSuggestion.fromJson(markdown);
      }
    }
    return (page, suggestions);
  }

  Future<BatchRecallReport> fetchRecallReport(int batchId) async {
    final response = await _session.get(
      'stock-batches/$batchId/recall-report/',
    );
    _session.ensureSuccess(response, 'Recall report failed with status');
    return BatchRecallReport.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<RecallNotifyResult> notifyAffectedCustomers(int batchId) async {
    final response = await _session.post(
      'stock-batches/$batchId/notify-affected/',
      body: const <String, Object?>{},
    );
    _session.ensureSuccess(response, 'Recall alert failed with status');
    return RecallNotifyResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  // -- custody (§6.2.2) ----------------------------------------------------

  Future<ConsignmentIncident> reportIncident(
    int unitId,
    ConsignmentIncidentDraft draft,
  ) async {
    final response = await _session.post(
      'stock-units/$unitId/report-incident/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Recording the incident failed with status',
    );
    return ConsignmentIncident.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<ConsignmentIncident>> fetchUnitIncidents(int unitId) async {
    final response = await _session.get('stock-units/$unitId/incidents/');
    _session.ensureSuccess(response, 'Unit incidents failed with status');
    return resultsFromDecoded(
      _session.decodedBody(response),
    ).map(ConsignmentIncident.fromJson).toList(growable: false);
  }

  Future<List<ConsignmentIncident>> fetchIncidents({
    bool openOnly = false,
    int page = 1,
  }) async {
    final response = await _session.get(
      'consignment-incidents/',
      query: {'page': '$page', if (openOnly) 'open_only': 'true'},
    );
    _session.ensureSuccess(response, 'Incidents request failed with status');
    return resultsFromDecoded(
      _session.decodedBody(response),
    ).map(ConsignmentIncident.fromJson).toList(growable: false);
  }

  Future<ConsignmentIncident> assessIncident(
    int incidentId, {
    required String responsibility,
    double? assessedValue,
    String note = '',
  }) async {
    final response = await _session.post(
      'consignment-incidents/$incidentId/assess/',
      body: <String, Object?>{
        'responsibility': responsibility,
        if (assessedValue != null)
          'assessed_value': assessedValue.toStringAsFixed(2),
        if (note.trim().isNotEmpty) 'note': note.trim(),
      },
    );
    _session.ensureSuccess(response, 'Assessing the claim failed with status');
    return ConsignmentIncident.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ConsignmentIncident> settleIncident(
    int incidentId, {
    required String resolution,
    String method = 'cash',
    int? replacementUnitId,
    String reference = '',
    String notes = '',
  }) async {
    final response = await _session.post(
      'consignment-incidents/$incidentId/settle/',
      body: <String, Object?>{
        'resolution': resolution,
        'method': method,
        'replacement_unit': ?replacementUnitId,
        if (reference.trim().isNotEmpty) 'reference': reference.trim(),
        if (notes.trim().isNotEmpty) 'notes': notes.trim(),
      },
    );
    _session.ensureSuccess(response, 'Settling the claim failed with status');
    return ConsignmentIncident.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<UnclaimedPayoutAging> fetchUnclaimedPayouts() async {
    final response = await _session.get('stock-units/unclaimed-payouts/');
    _session.ensureSuccess(
      response,
      'Unclaimed payouts request failed with status',
    );
    return UnclaimedPayoutAging.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  // -- opening identification (§6.10) --------------------------------------

  Future<List<OpeningIdentificationRow>> fetchOpeningWorklist() async {
    final response = await _session.get('stock-units/opening-worklist/');
    _session.ensureSuccess(response, 'Opening worklist failed with status');
    final decoded = _session.decodedBody(response);
    if (decoded is! List) {
      return const [];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(OpeningIdentificationRow.fromJson)
        .toList(growable: false);
  }

  Future<int> identifyOpeningStock({
    required int variantId,
    List<Map<String, Object?>> units = const [],
    List<Map<String, Object?>> batches = const [],
    bool captureLater = false,
  }) async {
    final response = await _session.post(
      'stock-units/identify-opening/',
      body: <String, Object?>{
        'variant': variantId,
        if (units.isNotEmpty) 'units': units,
        if (batches.isNotEmpty) 'batches': batches,
        if (captureLater) 'capture_later': true,
      },
    );
    _session.ensureSuccess(
      response,
      'Opening identification failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return (decoded['identified'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  Future<List<StockUnitTimelineEntry>> fetchUnitTimeline(int unitId) async {
    final response = await _session.get('stock-units/$unitId/timeline/');
    _session.ensureSuccess(response, 'Unit timeline failed with status');
    final decoded = _session.decodedBody(response);
    if (decoded is! List) {
      return const [];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(StockUnitTimelineEntry.fromJson)
        .toList(growable: false);
  }
}
