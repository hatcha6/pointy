import '../models/contact.dart';
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
}
