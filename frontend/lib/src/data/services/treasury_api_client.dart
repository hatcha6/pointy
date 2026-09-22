import '../models/card_terminal.dart';
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

  // --- card terminals --------------------------------------------------
  //
  // The terminal registry lives here rather than beside shop settings because
  // what it configures is a money route: a terminal's whole job, as far as
  // this app is concerned, is to say which account its slips belong to.

  Future<List<CardTerminal>> fetchCardTerminals() async {
    final response = await _session.get(
      'card-terminals/',
      query: {'page_size': '100'},
    );
    _session.ensureSuccess(
      response,
      'Card terminals request failed with status',
    );
    final body = _session.decodedBody(response);
    final results = body is Map ? body['results'] : body;
    if (results is! List) {
      return const [];
    }
    return results
        .whereType<Map>()
        .map((item) => CardTerminal.fromJson(item.cast<String, Object?>()))
        .toList();
  }

  Future<CardTerminal> createCardTerminal(CardTerminal terminal) async {
    final response = await _session.post(
      'card-terminals/',
      body: terminal.toJson(),
    );
    _session.ensureSuccess(response, 'Card terminal create failed with status');
    return CardTerminal.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<CardTerminal> updateCardTerminal(
    int terminalId,
    Map<String, Object?> changes,
  ) async {
    final response = await _session.patch(
      'card-terminals/$terminalId/',
      body: changes,
    );
    _session.ensureSuccess(response, 'Card terminal update failed with status');
    return CardTerminal.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteCardTerminal(int terminalId) async {
    final response = await _session.delete('card-terminals/$terminalId/');
    _session.ensureSuccess(response, 'Card terminal delete failed with status');
  }

  static String _day(DateTime value) =>
      value.toIso8601String().split('T').first;
}
