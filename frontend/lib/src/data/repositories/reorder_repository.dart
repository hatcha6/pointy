import '../../core/result.dart';
import '../models/purchase_submission.dart';
import '../models/reorder_queue.dart';
import '../services/pos_api_service.dart';

/// «إعادة الطلب»: what needs buying, and the draft order that buys it.
class ReorderRepository {
  const ReorderRepository(this._service);

  final PosApiService _service;

  Future<Result<ReorderQueue>> loadQueue({
    int? supplierId,
    required bool includeApproaching,
  }) {
    return Result.guard(
      () => _service.reorder.fetchQueue(
        supplierId: supplierId,
        includeApproaching: includeApproaching,
      ),
    );
  }

  Future<Result<PurchaseOrder>> createOrder({
    required int supplierId,
    required List<ReorderOrderLine> lines,
    String? idempotencyKey,
  }) {
    return Result.guard(
      () => _service.reorder.createOrder(
        supplierId: supplierId,
        lines: lines,
        idempotencyKey: idempotencyKey,
      ),
    );
  }
}
