import 'package:http/http.dart' as http;

import '../models/wallet.dart';
import 'api_session.dart';

/// The Daftar wallet endpoints. A refusal comes back as a [WalletException]
/// carrying the backend's code, so the app can say what happened in Arabic
/// and whether trying again can help.
class WalletApiClient {
  const WalletApiClient(this._session);

  final PosApiSession _session;

  Future<WalletOverview> fetchWallet() async {
    final response = await _session.get('wallet/');
    _ensure(response);
    return WalletOverview.fromJson(_map(response));
  }

  Future<WalletPage<WalletTopUp>> fetchTopUps({
    String? before,
    int limit = 30,
  }) async {
    final response = await _session.get(
      'wallet/topups/',
      query: {
        'limit': '$limit',
        if (before != null && before.isNotEmpty) 'before': before,
      },
    );
    _ensure(response);
    final json = _map(response);
    final items = json['topups'];
    return WalletPage(
      items: items is List
          ? items
                .whereType<Map<String, Object?>>()
                .map(WalletTopUp.fromJson)
                .toList()
          : const [],
      hasMore: json['has_more'] == true,
    );
  }

  Future<WalletPage<WalletEntry>> fetchEntries({
    String? before,
    int limit = 30,
  }) async {
    final response = await _session.get(
      'wallet/entries/',
      query: {
        'limit': '$limit',
        if (before != null && before.isNotEmpty) 'before': before,
      },
    );
    _ensure(response);
    final json = _map(response);
    final items = json['entries'];
    return WalletPage(
      items: items is List
          ? items
                .whereType<Map<String, Object?>>()
                .map(WalletEntry.fromJson)
                .toList()
          : const [],
      hasMore: json['has_more'] == true,
    );
  }

  /// Starts a top-up. [idempotencyKey] belongs to this attempt: sending it
  /// again returns the same checkout instead of opening a second one.
  Future<WalletTopUpStart> startTopUp({
    required String amount,
    required String method,
    required String idempotencyKey,
    bool? recordAsExpense,
  }) async {
    final response = await _session.post(
      'wallet/topups/',
      body: {
        'amount': amount,
        'method': method,
        'idempotency_key': idempotencyKey,
        'record_as_expense': ?recordAsExpense,
      },
    );
    _ensure(response);
    return WalletTopUpStart.fromJson(_map(response));
  }

  Future<WalletTopUp> fetchTopUp(String id) async {
    final response = await _session.get(
      'wallet/topups/${Uri.encodeComponent(id)}/',
    );
    _ensure(response);
    final topUp = _map(response)['top_up'];
    return WalletTopUp.fromJson(
      topUp is Map<String, Object?> ? topUp : const {},
    );
  }

  Future<WalletSettings> updateSettings({
    required bool recordTopUpsAsExpenses,
  }) async {
    final response = await _session.patch(
      'wallet/settings/',
      body: {'record_topups_as_expenses': recordTopUpsAsExpenses},
    );
    _ensure(response);
    return WalletSettings.fromJson(_map(response));
  }

  void _ensure(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WalletException.fromResponse(
        response.statusCode,
        _session.body(response),
      );
    }
  }

  Map<String, Object?> _map(http.Response response) {
    final decoded = _session.decodedBody(response);
    return decoded is Map<String, Object?> ? decoded : const {};
  }
}
