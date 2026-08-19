import '../../features/payments/models/payment_record.dart';
import '../models/print_job.dart';
import '../models/sale_order.dart';
import '../models/sale_order_page.dart';
import 'api_session.dart';

class SalesApiClient {
  const SalesApiClient(this._session);

  final PosApiSession _session;

  Future<SaleOrder> checkout(
    SaleCheckoutDraft draft, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'orders/checkout/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(response, 'Checkout failed with status');
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SaleOrderPage> fetchOrders({
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) async {
    final response = await _session.get(
      'orders/',
      query: query.toQueryParameters(page: page),
    );
    _session.throwApiException(response, 'Order list failed with status');
    return SaleOrderPage.fromAny(_session.decodedBody(response));
  }

  Future<SaleOrder> fetchOrder(int saleOrderId) async {
    final response = await _session.get('orders/$saleOrderId/');
    _session.throwApiException(response, 'Order detail failed with status');
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> sendInvoiceSms(int saleOrderId) async {
    final response = await _session.post(
      'crm/orders/$saleOrderId/send-invoice-sms/',
    );
    _session.throwApiException(response, 'Send invoice SMS failed with status');
  }

  /// Customer money-IN payments for the Payments hub, read through the backend
  /// ledger projection. Optional [method], [customerId] and a [paidAtGte] /
  /// [paidAtLte] window narrow the list; newest-paid first.
  Future<CustomerPaymentPage> fetchCustomerPayments({
    String? method,
    int? customerId,
    DateTime? paidAtGte,
    DateTime? paidAtLte,
    int page = 1,
  }) async {
    final response = await _session.get(
      'payments/',
      query: {
        'page': '$page',
        'ordering': '-paid_at',
        if (method != null && method.isNotEmpty) 'method': method,
        if (customerId != null) 'order__customer': '$customerId',
        if (paidAtGte != null) 'paid_at__gte': paidAtGte.toIso8601String(),
        if (paidAtLte != null) 'paid_at__lte': paidAtLte.toIso8601String(),
      },
    );
    _session.throwApiException(
      response,
      'Customer payment list failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return CustomerPaymentPage.fromJson(decoded);
    }
    return const CustomerPaymentPage(payments: [], hasMore: false);
  }

  /// Converts an OPEN quotation into a standard or credit sale, optionally
  /// taking a down-payment ([amountReceived]). Returns the NEW order.
  Future<SaleOrder> convertQuotation(
    int quotationId, {
    required SaleType saleType,
    double? amountReceived,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'orders/$quotationId/convert/',
      body: {
        'sale_type': saleType.apiValue,
        if (amountReceived != null)
          'amount_received': amountReceived.toStringAsFixed(2),
      },
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Quotation conversion failed with status',
    );
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Records a payment against a single (credit) invoice. Cards are allowed
  /// here — pass [cardReceiptUrl] for the card method. Returns the updated
  /// order.
  Future<SaleOrder> recordInvoicePayment(
    int saleOrderId, {
    required String method,
    required double amount,
    String cardReceiptUrl = '',
    String? idempotencyKey,
  }) async {
    final normalizedReceiptUrl = cardReceiptUrl.trim();
    final response = await _session.post(
      'orders/$saleOrderId/record-payment/',
      body: {
        'method': method,
        'amount': amount.toStringAsFixed(2),
        if (normalizedReceiptUrl.isNotEmpty)
          'card_receipt_url': normalizedReceiptUrl,
      },
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(response, 'Invoice payment failed with status');
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Assigns or changes the customer who owes a debt (credit) invoice. The
  /// backend allows this only while no payment has been recorded against it.
  /// Returns the updated order.
  Future<SaleOrder> assignSaleOrderCustomer(
    int saleOrderId, {
    required int customerId,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'orders/$saleOrderId/assign-customer/',
      body: {'customer': customerId},
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Assigning the invoice customer failed with status',
    );
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SaleDiscountPreview> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    final response = await _session.post(
      'orders/discount-preview/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Sale discount preview failed with status',
    );
    return SaleDiscountPreview.fromJson(
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

  Future<SaleOrder> exchangeSaleOrderItems({
    required int saleOrderId,
    required SaleExchangeDraft draft,
  }) async {
    final response = await _session.post(
      'orders/$saleOrderId/exchange-items/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Sale exchange request failed with status',
    );
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Returns-desk lookup: fetch a single invoice by its receipt number. Gated
  /// server-side by ``sales.process_return_lookup``.
  Future<SaleOrder> lookupSaleOrderByReceipt(String receiptNumber) async {
    final response = await _session.get(
      'orders/lookup/',
      query: {'receipt': receiptNumber},
    );
    // Carry the status code out: the returns desk must tell a genuine 404
    // (no such receipt) apart from an unreachable or failing server.
    _session.throwApiException(response, 'Invoice lookup failed with status');
    return SaleOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
