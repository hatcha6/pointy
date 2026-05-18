import '../../core/result.dart';
import '../models/stock_item.dart';
import '../models/stock_movement.dart';
import '../models/stock_movement_page.dart';
import '../services/pos_api_service.dart';

class InventoryRepository {
  InventoryRepository(this._service);

  final PosApiService _service;

  Future<Result<StockItem?>> loadStockForProduct(int productId) async {
    try {
      return Ok(await _service.fetchStockForProduct(productId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<StockMovementPage>> loadMovementsForProduct(
    int productId, {
    int page = 1,
  }) async {
    try {
      return Ok(
        await _service.fetchStockMovementsForProduct(productId, page: page),
      );
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<StockMovement>> createMovement(StockMovementDraft draft) async {
    try {
      return Ok(await _service.createStockMovement(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
