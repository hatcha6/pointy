import '../models/print_job.dart';
import '../models/sale_order.dart';
import 'api_session.dart';

class SalesApiClient {
  const SalesApiClient(this._session);

  final PosApiSession _session;

  Future<SaleOrder> checkout(SaleCheckoutDraft draft) async {
    final response = await _session.post(
      'orders/checkout/',
      body: draft.toJson(),
    );
    _session.throwApiException(response, 'Checkout failed with status');
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PrintJob> requestSaleReprint(int saleOrderId) async {
    final response = await _session.post('orders/$saleOrderId/reprint/');
    _session.ensureSuccess(response, 'Sale reprint request failed with status');
    return PrintJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SaleOrder> voidSaleOrder({
    required int saleOrderId,
    required SaleVoidDraft draft,
  }) async {
    final response = await _session.post(
      'orders/$saleOrderId/void/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Sale void request failed with status');
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SaleOrder> returnSaleOrderItems({
    required int saleOrderId,
    required SaleReturnDraft draft,
  }) async {
    final response = await _session.post(
      'orders/$saleOrderId/return-items/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Sale return request failed with status');
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
