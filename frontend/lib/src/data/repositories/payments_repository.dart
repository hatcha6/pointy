import '../../core/result.dart';
import '../../features/payments/models/payment_record.dart';
import '../models/purchase_submission.dart' show SupplierPaymentPage;
import '../models/sale_order.dart' show SaleOrder, SaleType;
import '../services/pos_api_service.dart';

/// Read access for the Payments hub (الخزينة): customer money-IN payments and
/// supplier money-OUT payments, plus the convert-quotation write that the
/// invoice surface drives. All methods are [Result]-wrapped, matching the other
/// repositories.
class PaymentsRepository {
  const PaymentsRepository(this._service);

  final PosApiService _service;

  Future<Result<CustomerPaymentPage>> loadCustomerPayments({
    String? method,
    int? customerId,
    DateTime? paidAtGte,
    DateTime? paidAtLte,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchCustomerPayments(
        method: method,
        customerId: customerId,
        paidAtGte: paidAtGte,
        paidAtLte: paidAtLte,
        page: page,
      ),
    );
  }

  Future<Result<SupplierPaymentPage>> loadSupplierPayments({
    int? supplierId,
    int? purchaseOrderId,
    String? method,
    DateTime? paidAtGte,
    DateTime? paidAtLte,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchSupplierPayments(
        supplierId: supplierId,
        purchaseOrderId: purchaseOrderId,
        method: method,
        paidAtGte: paidAtGte,
        paidAtLte: paidAtLte,
        page: page,
      ),
    );
  }

  /// Converts an OPEN quotation into a standard or credit sale. Returns the NEW
  /// order so the caller can navigate to it.
  Future<Result<SaleOrder>> convertQuotation(
    int orderId, {
    required SaleType saleType,
    double? amountReceived,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.convertQuotation(
        orderId,
        saleType: saleType,
        amountReceived: amountReceived,
        idempotencyKey: idempotencyKey,
      ),
    );
  }
}
