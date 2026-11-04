import '../models/purchase_submission.dart';
import '../models/reorder_queue.dart';
import 'api_session.dart';

/// The reorder queue and the draft order it creates. Both need
/// `purchasing.add_purchaseorder`.
class ReorderApiClient {
  const ReorderApiClient(this._session);

  final PosApiSession _session;

  Future<ReorderQueue> fetchQueue({
    int? supplierId,
    required bool includeApproaching,
  }) async {
    final response = await _session.get(
      'purchase-orders/reorder-queue/',
      query: {
        if (supplierId != null) 'supplier': '$supplierId',
        if (!includeApproaching) 'approaching': 'false',
      },
    );
    _session.throwApiException(response, 'Reorder queue request failed');
    return ReorderQueue.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  Future<PurchaseOrder> createOrder({
    required int supplierId,
    required List<ReorderOrderLine> lines,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'purchase-orders/from-reorder/',
      body: {
        'supplier': supplierId,
        'lines': [for (final line in lines) line.toJson()],
      },
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(response, 'Reorder purchase order failed');
    return PurchaseOrder.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }
}
