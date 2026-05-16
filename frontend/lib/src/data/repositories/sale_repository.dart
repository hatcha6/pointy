import '../../core/result.dart';
import '../models/sale_order.dart';
import '../services/pos_api_service.dart';

class SaleRepository {
  SaleRepository(this._service);

  final PosApiService _service;

  Future<Result<SaleOrder>> checkout(SaleCheckoutDraft draft) async {
    try {
      return Ok(await _service.checkout(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<List<SaleOrder>>> loadOrdersForSession(int sessionId) async {
    try {
      return Ok(await _service.fetchRegisterSessionOrders(sessionId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
