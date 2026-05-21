import '../../core/result.dart';
import '../models/stock_item.dart';
import '../models/stock_movement.dart';
import '../models/stock_movement_page.dart';
import '../services/pos_api_service.dart';

class InventoryRepository {
  InventoryRepository(this._service);

  final PosApiService _service;

  Future<Result<StockItem?>> loadStockForProduct(int productId) async {
    return Result.guard(() => _service.fetchStockForProduct(productId));
  }

  Future<Result<StockItem?>> loadStockForVariant(int variantId) async {
    return Result.guard(() => _service.fetchStockForVariant(variantId));
  }

  Future<Result<StockMovementPage>> loadMovementsForProduct(
    int productId, {
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchStockMovementsForProduct(productId, page: page),
    );
  }

  Future<Result<StockMovementPage>> loadMovementsForVariant(
    int variantId, {
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchStockMovementsForVariant(variantId, page: page),
    );
  }

  Future<Result<StockMovement>> createMovement(StockMovementDraft draft) async {
    return Result.guard(() => _service.createStockMovement(draft));
  }
}
