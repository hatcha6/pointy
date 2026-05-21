import '../models/stock_item.dart';
import '../models/stock_movement.dart';
import '../models/stock_movement_page.dart';
import 'api_session.dart';

class InventoryApiClient {
  const InventoryApiClient(this._session);

  final PosApiSession _session;

  Future<StockItem?> fetchStockForProduct(int productId) async {
    final response = await _session.get(
      'stock/',
      query: {'product': '$productId'},
    );
    _session.ensureSuccess(response, 'Stock request failed with status');

    final results = resultsFromDecoded(_session.decodedBody(response));
    if (results.isEmpty) {
      return null;
    }
    return StockItem.fromJson(results.first);
  }

  Future<StockItem?> fetchStockForVariant(int variantId) async {
    final response = await _session.get(
      'stock/',
      query: {'variant': '$variantId'},
    );
    _session.ensureSuccess(response, 'Stock request failed with status');

    final results = resultsFromDecoded(_session.decodedBody(response));
    if (results.isEmpty) {
      return null;
    }
    return StockItem.fromJson(results.first);
  }

  Future<StockMovementPage> fetchStockMovementsForProduct(
    int productId, {
    int page = 1,
  }) async {
    final response = await _session.get(
      'stock-movements/',
      query: {'product': '$productId', 'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Stock movement request failed with status',
    );

    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return StockMovementPage.fromJson(decoded);
    }
    if (decoded is List<Object?>) {
      return StockMovementPage(
        movements: decoded
            .whereType<Map<String, Object?>>()
            .map(StockMovement.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const StockMovementPage(movements: [], hasMore: false);
  }

  Future<StockMovementPage> fetchStockMovementsForVariant(
    int variantId, {
    int page = 1,
  }) async {
    final response = await _session.get(
      'stock-movements/',
      query: {'variant': '$variantId', 'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Stock movement request failed with status',
    );

    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return StockMovementPage.fromJson(decoded);
    }
    if (decoded is List<Object?>) {
      return StockMovementPage(
        movements: decoded
            .whereType<Map<String, Object?>>()
            .map(StockMovement.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const StockMovementPage(movements: [], hasMore: false);
  }

  Future<StockMovement> createStockMovement(StockMovementDraft draft) async {
    final response = await _session.post(
      'stock-movements/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Stock movement create failed with status',
    );
    return StockMovement.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
