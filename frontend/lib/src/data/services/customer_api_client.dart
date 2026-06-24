import '../models/customer_activity.dart';
import '../models/contact.dart';
import '../models/payment_card.dart';
import '../models/sale_order_page.dart';
import 'api_session.dart';

class CustomerApiClient {
  const CustomerApiClient(this._session);

  final PosApiSession _session;

  Future<CustomerPage> fetchCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'customers/',
      query: query.toQueryParameters(page: page),
    );
    _session.throwApiException(response, 'Customer list failed with status');
    return CustomerPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Customer> createCustomer(CustomerDraft draft) async {
    final response = await _session.post('customers/', body: draft.toJson());
    _session.throwApiException(response, 'Customer create failed with status');
    return Customer.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Customer> fetchCustomer(int customerId) async {
    final response = await _session.get('customers/$customerId/');
    _session.throwApiException(response, 'Customer detail failed with status');
    return Customer.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CustomerSalesSummary> fetchCustomerSalesSummary(int customerId) async {
    final response = await _session.get('customers/$customerId/sales-summary/');
    _session.throwApiException(
      response,
      'Customer sales summary failed with status',
    );
    return CustomerSalesSummary.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Records a payment against the customer's account (cash/transfer only —
  /// the backend allocates it oldest-first across open debt invoices) and
  /// returns the refreshed sales-summary.
  Future<CustomerSalesSummary> recordCustomerAccountPayment(
    int customerId, {
    required String method,
    required double amount,
    String cardReceiptUrl = '',
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'customers/$customerId/record-payment/',
      body: {
        'method': method,
        'amount': amount.toStringAsFixed(2),
        if (cardReceiptUrl.isNotEmpty) 'card_receipt_url': cardReceiptUrl,
      },
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Customer account payment failed with status',
    );
    return CustomerSalesSummary.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SaleOrderPage> fetchCustomerOrders({
    required int customerId,
    int page = 1,
  }) async {
    final response = await _session.get(
      'customers/$customerId/orders/',
      query: {'page': '$page'},
    );
    _session.throwApiException(
      response,
      'Customer order history failed with status',
    );
    return SaleOrderPage.fromAny(_session.decodedBody(response));
  }

  Future<CustomerAdjustmentHistoryPage> fetchCustomerAdjustments({
    required int customerId,
    int page = 1,
  }) async {
    final response = await _session.get(
      'customers/$customerId/adjustments/',
      query: {'page': '$page'},
    );
    _session.throwApiException(
      response,
      'Customer adjustment history failed with status',
    );
    return CustomerAdjustmentHistoryPage.fromAny(
      _session.decodedBody(response),
    );
  }

  Future<Customer> patchCustomer(
    int customerId,
    Map<String, Object?> body,
  ) async {
    final response = await _session.patch('customers/$customerId/', body: body);
    _session.throwApiException(response, 'Customer update failed with status');
    return Customer.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Folds [sourceId] into [customerId]: the source's cards, orders and other
  /// records re-point to the target and the source is deleted server-side.
  Future<Customer> mergeCustomer({
    required int customerId,
    required int sourceId,
  }) async {
    final response = await _session.post(
      'customers/$customerId/merge/',
      body: {'source_id': sourceId},
    );
    _session.throwApiException(response, 'Customer merge failed with status');
    return Customer.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PaymentCardPage> fetchCustomerCards({
    required int customerId,
    int page = 1,
  }) async {
    final response = await _session.get(
      'payment-cards/',
      query: {'customer': '$customerId', 'page': '$page'},
    );
    _session.throwApiException(
      response,
      'Payment card list failed with status',
    );
    return PaymentCardPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PaymentCard> reassignCard({
    required int cardId,
    required int customerId,
  }) async {
    final response = await _session.post(
      'payment-cards/$cardId/reassign/',
      body: {'customer_id': customerId},
    );
    _session.throwApiException(response, 'Card reassign failed with status');
    return PaymentCard.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
