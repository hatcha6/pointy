import '../models/customer_activity.dart';
import '../models/contact.dart';
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
}
