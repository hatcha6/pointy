import '../models/balance_entry.dart';
import '../models/contact.dart';
import '../models/customer_activity.dart';
import 'api_session.dart';

/// Opening balances and adjustments on customers' and suppliers' accounts,
/// plus the two account-level actions that settle them: spending a
/// customer's credit, and paying a supplier on account.
class BalanceApiClient {
  const BalanceApiClient(this._session);

  final PosApiSession _session;

  Future<BalanceEntryPage> fetchEntries({
    required BalanceParty party,
    required int partyId,
    int page = 1,
  }) async {
    final response = await _session.get(
      party.path,
      query: {party.fieldName: '$partyId', 'page': '$page'},
    );
    _session.throwApiException(response, 'Balance entries failed with status');
    return BalanceEntryPage.fromAny(_session.decodedBody(response));
  }

  Future<BalanceEntry> createEntry({
    required BalanceParty party,
    required int partyId,
    required BalanceEntryDraft draft,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      party.path,
      body: {party.fieldName: partyId, ...draft.toJson()},
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(response, 'Balance entry failed with status');
    return BalanceEntry.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Settles a balance with cash through the caller's open drawer: pays a
  /// customer what the shop owes them, takes in what a supplier owes it, or —
  /// for an employee, whose account runs both ways — whichever side
  /// [settles] names.
  Future<BalanceEntry> refund({
    required BalanceParty party,
    required int partyId,
    required double amount,
    String note = '',
    BalanceDirection? settles,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      '${party.path}refund/',
      body: {
        party.fieldName: partyId,
        'amount': amount.toStringAsFixed(2),
        if (note.trim().isNotEmpty) 'note': note.trim(),
        'settles': ?settles?.apiValue,
      },
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(response, 'Balance refund failed with status');
    return BalanceEntry.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<BalanceEntry> cancelEntry({
    required BalanceParty party,
    required int entryId,
    required String reason,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      '${party.path}$entryId/cancel/',
      body: {'reason': reason},
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Balance entry cancel failed with status',
    );
    return BalanceEntry.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Spends the credit the shop holds for a customer against what they owe;
  /// answers with the refreshed summary.
  Future<CustomerSalesSummary> applyCustomerCredit(
    int customerId, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'customers/$customerId/apply-credit/',
      body: const <String, Object?>{},
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(response, 'Apply credit failed with status');
    return CustomerSalesSummary.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Pays a supplier on account: the server splits it across what the shop
  /// owes them, oldest first. Answers with the refreshed supplier and the
  /// payments it wrote.
  Future<SupplierAccountPaymentResult> recordSupplierAccountPayment(
    int supplierId, {
    required String method,
    required double amount,
    String reference = '',
    String notes = '',
    int? moneyAccountId,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'suppliers/$supplierId/record-payment/',
      body: {
        'method': method,
        'amount': amount.toStringAsFixed(2),
        if (reference.trim().isNotEmpty) 'reference': reference.trim(),
        if (notes.trim().isNotEmpty) 'notes': notes.trim(),
        'money_account': ?moneyAccountId,
      },
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Supplier account payment failed with status',
    );
    return SupplierAccountPaymentResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}

class SupplierAccountPaymentResult {
  const SupplierAccountPaymentResult({
    required this.supplier,
    required this.paymentIds,
  });

  final SupplierContact supplier;

  /// One per document the money settled, oldest first. The first is what a
  /// proof of payment for the whole amount is keyed on.
  final List<int> paymentIds;

  factory SupplierAccountPaymentResult.fromJson(Map<String, Object?> json) {
    return SupplierAccountPaymentResult(
      supplier: SupplierContact.fromJson(
        (json['supplier'] as Map<String, Object?>?) ?? const {},
      ),
      paymentIds: (json['payments'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map((row) => row['id'])
          .whereType<num>()
          .map((id) => id.toInt())
          .toList(growable: false),
    );
  }
}
