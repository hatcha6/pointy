import '../models/money_position.dart';
import 'api_session.dart';

/// The money position (الخزينة): what the shop should be holding, where, and
/// the events that put it there.
class TreasuryApiClient {
  const TreasuryApiClient(this._session);

  final PosApiSession _session;

  Future<MoneyPosition> fetchPosition({DateTime? asOf}) async {
    final response = await _session.get(
      'treasury/position/',
      query: {if (asOf != null) 'as_of': _day(asOf)},
    );
    _session.ensureSuccess(
      response,
      'Money position request failed with status',
    );
    return MoneyPosition.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MoneyMovementPage> fetchAccountMovements(
    int accountId, {
    DateTime? start,
    DateTime? end,
  }) async {
    final response = await _session.get(
      'treasury/accounts/$accountId/movements/',
      query: {
        if (start != null) 'start': _day(start),
        if (end != null) 'end': _day(end),
      },
    );
    _session.ensureSuccess(
      response,
      'Account movements request failed with status',
    );
    return MoneyMovementPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MoneyCount> recordCount({
    required int accountId,
    required double countedAmount,
    String note = '',
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'money-counts/',
      body: {
        'account': accountId,
        'counted_amount': countedAmount.toStringAsFixed(2),
        'note': note,
      },
      idempotencyKey: idempotencyKey,
    );
    _session.ensureSuccess(response, 'Money count failed with status');
    return MoneyCount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> recordTransfer(
    MoneyTransferDraft draft, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'money-transfers/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.ensureSuccess(response, 'Money transfer failed with status');
  }

  Future<List<MoneyAccount>> fetchAccounts() async {
    final response = await _session.get(
      'money-accounts/',
      query: {'page_size': '100'},
    );
    _session.ensureSuccess(
      response,
      'Money accounts request failed with status',
    );
    final body = _session.decodedBody(response);
    final results = body is Map ? body['results'] : body;
    if (results is! List) {
      return const [];
    }
    return results
        .whereType<Map>()
        .map((item) => MoneyAccount.fromJson(item.cast<String, Object?>()))
        .toList();
  }

  Future<MoneyAccount> createAccount(MoneyAccount account) async {
    final response = await _session.post(
      'money-accounts/',
      body: account.toJson(),
    );
    _session.ensureSuccess(response, 'Money account create failed with status');
    return MoneyAccount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<MoneyAccount> updateAccount(
    int accountId,
    Map<String, Object?> changes,
  ) async {
    final response = await _session.patch(
      'money-accounts/$accountId/',
      body: changes,
    );
    _session.ensureSuccess(response, 'Money account update failed with status');
    return MoneyAccount.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  static String _day(DateTime value) =>
      value.toIso8601String().split('T').first;
}
