import '../../core/result.dart';
import '../models/stock_transfer.dart';
import '../models/stock_unit.dart';
import '../models/warehouse.dart';
import '../services/pos_api_service.dart';

/// The places a shop keeps stock.
///
/// Most shops have exactly one and never open a second, so everything here is
/// written to be correct and quiet in that case: one warehouse is not a list
/// worth showing off, and nothing pushes an owner towards a second room they do
/// not have.
class WarehouseRepository {
  const WarehouseRepository(this._service);

  final PosApiService _service;

  Future<Result<List<Warehouse>>> loadWarehouses({bool activeOnly = false}) {
    return Result.guard(() => _service.fetchWarehouses(activeOnly: activeOnly));
  }

  Future<Result<Warehouse>> createWarehouse(Warehouse warehouse) {
    return Result.guard(() => _service.createWarehouse(warehouse));
  }

  Future<Result<Warehouse>> updateWarehouse(Warehouse warehouse) {
    return Result.guard(() => _service.updateWarehouse(warehouse));
  }

  Future<Result<void>> deleteWarehouse(int id) {
    return Result.guard(() => _service.deleteWarehouse(id));
  }

  /// Where every unit of one product is sitting, newest place first.
  Future<Result<List<WarehouseStockRow>>> loadStockByWarehouse(int variantId) {
    return Result.guard(() => _service.fetchStockByWarehouse(variantId));
  }

  Future<Result<RegisterProfile>> loadMyRegisterProfile() {
    return Result.guard(() => _service.fetchMyRegisterProfile());
  }

  Future<Result<RegisterProfile>> assignMyRegisterWarehouse({
    required int warehouseId,
    String? name,
  }) {
    return Result.guard(
      () => _service.assignMyRegisterWarehouse(
        warehouseId: warehouseId,
        name: name,
      ),
    );
  }

  Future<Result<List<StockTransfer>>> loadTransfers({String? status}) {
    return Result.guard(() => _service.fetchTransfers(status: status));
  }

  Future<Result<StockTransfer>> createTransfer(StockTransferDraft draft) {
    return Result.guard(() => _service.createTransfer(draft));
  }

  Future<Result<StockTransfer>> dispatchTransfer(
    int id, {
    Map<int, TransferLinePick> picks = const {},
  }) {
    return Result.guard(() => _service.dispatchTransfer(id, picks: picks));
  }

  Future<Result<StockTransfer>> receiveTransfer(
    int id,
    Map<int, double> lines, {
    String note = '',
    Map<int, TransferLinePick> picks = const {},
  }) {
    return Result.guard(
      () => _service.receiveTransfer(id, lines, note: note, picks: picks),
    );
  }

  Future<Result<StockTransfer>> cancelTransfer(int id, String reason) {
    return Result.guard(() => _service.cancelTransfer(id, reason));
  }

  Future<Result<List<WarehouseStockRow>>> searchStockAt({
    required int warehouseId,
    String search = '',
  }) {
    return Result.guard(
      () => _service.searchStockAt(warehouseId: warehouseId, search: search),
    );
  }
}
