import '../../core/result.dart';
import '../models/stock_count.dart';
import '../models/stock_count_draft.dart';
import '../models/stock_count_line.dart';
import '../services/pos_api_service.dart';

class StockCountRepository {
  const StockCountRepository(this._service);

  final PosApiService _service;

  Future<Result<StockCount>> startCount(StockCountStartDraft draft) {
    return Result.guard(() => _service.startStockCount(draft));
  }

  Future<Result<StockCount?>> loadCurrentCount() {
    return Result.guard(() => _service.fetchCurrentStockCount());
  }

  Future<Result<StockCountPage>> loadCounts({String? status, int page = 1}) {
    return Result.guard(
      () => _service.fetchStockCounts(status: status, page: page),
    );
  }

  Future<Result<StockCount>> loadCount(int countId) {
    return Result.guard(() => _service.fetchStockCount(countId));
  }

  Future<Result<StockCountLine>> recordLine(
    int countId,
    StockCountLineDraft draft,
  ) {
    return Result.guard(() => _service.recordStockCountLine(countId, draft));
  }

  Future<Result<List<StockCountLine>>> loadReconciliation(int countId) {
    return Result.guard(() => _service.fetchStockCountReconciliation(countId));
  }

  Future<Result<StockCount>> applyCount(
    int countId, {
    required String idempotencyKey,
  }) {
    return Result.guard(
      () => _service.applyStockCount(countId, idempotencyKey: idempotencyKey),
    );
  }

  Future<Result<StockCount>> cancelCount(int countId) {
    return Result.guard(() => _service.cancelStockCount(countId));
  }
}
