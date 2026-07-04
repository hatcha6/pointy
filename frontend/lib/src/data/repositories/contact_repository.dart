import '../../core/result.dart';
import '../models/contact.dart';
import '../models/customer_activity.dart';
import '../models/payment_card.dart';
import '../models/sale_order_page.dart';
import '../services/pos_api_service.dart';

class ContactRepository {
  const ContactRepository(this._service);

  final PosApiService _service;

  Future<Result<CustomerPage>> loadCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchCustomers(query: query, page: page),
    );
  }

  Future<Result<SupplierPage>> loadSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchSuppliers(query: query, page: page),
    );
  }

  Future<Result<SupplierContact>> loadSupplier(int supplierId) async {
    return Result.guard(() => _service.fetchSupplier(supplierId));
  }

  Future<Result<Customer>> loadCustomer(int customerId) async {
    return Result.guard(() => _service.fetchCustomer(customerId));
  }

  Future<Result<void>> setCustomerConsent(
    int customerId, {
    bool? marketingOptedOut,
    bool? doNotContact,
  }) async {
    return Result.guard(
      () => _service.setCustomerConsent(
        customerId,
        marketingOptedOut: marketingOptedOut,
        doNotContact: doNotContact,
      ),
    );
  }

  Future<Result<CustomerSalesSummary>> loadCustomerSalesSummary(
    int customerId,
  ) async {
    return Result.guard(() => _service.fetchCustomerSalesSummary(customerId));
  }

  /// Records a cash/transfer payment against the customer's account; the
  /// backend allocates it oldest-first across open debt invoices and returns
  /// the refreshed sales-summary.
  Future<Result<CustomerSalesSummary>> recordCustomerAccountPayment(
    int customerId, {
    required String method,
    required double amount,
    String cardReceiptUrl = '',
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.recordCustomerAccountPayment(
        customerId,
        method: method,
        amount: amount,
        cardReceiptUrl: cardReceiptUrl,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<SaleOrderPage>> loadCustomerOrderHistory({
    required int customerId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchCustomerOrders(customerId: customerId, page: page),
    );
  }

  Future<Result<CustomerAdjustmentHistoryPage>> loadCustomerAdjustmentHistory({
    required int customerId,
    int page = 1,
  }) async {
    return Result.guard(
      () =>
          _service.fetchCustomerAdjustments(customerId: customerId, page: page),
    );
  }

  Future<Result<Customer>> createCustomer(CustomerDraft draft) async {
    return Result.guard(() => _service.createCustomer(draft));
  }

  Future<Result<Customer>> patchCustomer(
    int customerId,
    Map<String, Object?> body,
  ) async {
    return Result.guard(() => _service.patchCustomer(customerId, body));
  }

  /// Full profile edit. Editing an auto-created card placeholder is a
  /// deliberate act of claiming it, so [claimAutoCreated] also clears the
  /// placeholder flag (mirroring the "name customer" flow) — otherwise the
  /// freshly edited customer would stay hidden from the customers list.
  Future<Result<Customer>> updateCustomer(
    int customerId,
    CustomerDraft draft, {
    bool claimAutoCreated = false,
  }) async {
    final body = draft.toJson();
    if (claimAutoCreated) {
      body['is_auto_created'] = false;
    }
    return Result.guard(() => _service.patchCustomer(customerId, body));
  }

  Future<Result<Customer>> mergeCustomer({
    required int customerId,
    required int sourceId,
  }) async {
    return Result.guard(
      () => _service.mergeCustomer(customerId: customerId, sourceId: sourceId),
    );
  }

  Future<Result<PaymentCardPage>> loadCustomerCards({
    required int customerId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchCustomerCards(customerId: customerId, page: page),
    );
  }

  Future<Result<PaymentCard>> reassignCard({
    required int cardId,
    required int customerId,
  }) async {
    return Result.guard(
      () => _service.reassignCard(cardId: cardId, customerId: customerId),
    );
  }

  Future<Result<SupplierContact>> createSupplier(SupplierDraft draft) async {
    return Result.guard(() => _service.createSupplier(draft));
  }

  Future<Result<SupplierContact>> updateSupplier(
    int supplierId,
    SupplierDraft draft,
  ) async {
    return Result.guard(
      () => _service.patchSupplier(supplierId, draft.toJson()),
    );
  }
}
