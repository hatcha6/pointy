import 'package:http/http.dart' as http;

import '../models/wallet.dart';
import 'api_session.dart';

/// What the shop says about a bank transfer it made to the company.
class WalletBankTransferRequest {
  const WalletBankTransferRequest({
    required this.amount,
    required this.channel,
    required this.payerBank,
    required this.payerAccount,
    required this.payerIban,
    required this.receipt,
    required this.idempotencyKey,
    this.toAccount = '',
    this.recordAsExpense,
  });

  final String amount;
  final WalletTransferChannel channel;
  final String payerBank;
  final String payerAccount;
  final String payerIban;
  final WalletTransferReceipt receipt;
  final String idempotencyKey;
  final String toAccount;
  final bool? recordAsExpense;
}

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

  /// One account's statement: the main wallet, the SMS or the voucher balance.
  Future<WalletPage<WalletEntry>> fetchEntries({
    String? before,
    int limit = 30,
    WalletAccount account = WalletAccount.main,
  }) async {
    final response = await _session.get(
      'wallet/entries/',
      query: {
        'limit': '$limit',
        if (before != null && before.isNotEmpty) 'before': before,
        if (account != WalletAccount.main) 'account': account.key,
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
  /// again returns the same payment instead of starting a second one.
  /// [userIdentifier] is the payer's phone or wallet card number and
  /// [birthYear] Sadad's second factor; a bank card takes neither.
  Future<WalletTopUpStart> startTopUp({
    required String amount,
    required String method,
    required String idempotencyKey,
    bool? recordAsExpense,
    String userIdentifier = '',
    String birthYear = '',
  }) async {
    final response = await _session.post(
      'wallet/topups/',
      body: {
        'amount': amount,
        'method': method,
        'idempotency_key': idempotencyKey,
        'record_as_expense': ?recordAsExpense,
        if (userIdentifier.isNotEmpty) 'user_identifier': userIdentifier,
        if (birthYear.isNotEmpty) 'birth_year': birthYear,
      },
    );
    _ensure(response);
    return WalletTopUpStart.fromJson(_map(response));
  }

  /// Sends a bank transfer and its receipt for the company's team to check.
  /// The receipt goes up with it, or — when the paired phone sent it — by its
  /// attachment id on the shop's server. [onProgress] follows the upload.
  Future<WalletTopUpStart> startBankTransfer(
    WalletBankTransferRequest request, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final receipt = request.receipt;
    final response = await _session.postMultipart(
      'wallet/topups/bank-transfer/',
      fields: {
        'amount': request.amount,
        'channel': request.channel.key,
        'payer_bank': request.payerBank,
        'payer_account': request.payerAccount,
        'payer_iban': request.payerIban,
        'idempotency_key': request.idempotencyKey,
        if (request.toAccount.isNotEmpty) 'to_account': request.toAccount,
        if (request.recordAsExpense != null)
          'record_as_expense': '${request.recordAsExpense}',
        if (receipt.attachmentId != null)
          'receipt_attachment_id': '${receipt.attachmentId}',
      },
      files: [
        if (receipt.bytes != null)
          ApiMultipartFile(
            fieldName: 'receipt',
            filename: receipt.name.isEmpty ? 'receipt' : receipt.name,
            bytes: receipt.bytes!,
            contentType: receipt.contentType.isEmpty
                ? 'application/octet-stream'
                : receipt.contentType,
          ),
      ],
      // A phone photo over a slow uplink: longer than a JSON call.
      timeout: const Duration(minutes: 2),
      onProgress: onProgress,
    );
    _ensure(response);
    return WalletTopUpStart.fromJson(_map(response));
  }

  /// Sends the code the payer's provider texted them.
  Future<WalletTopUpConfirmation> confirmTopUp({
    required String id,
    required String otp,
  }) async {
    final response = await _session.post(
      'wallet/topups/${Uri.encodeComponent(id)}/confirm/',
      body: {'otp': otp},
    );
    _ensure(response);
    return WalletTopUpConfirmation.fromJson(_map(response));
  }

  /// Calls off a top-up still waiting for its code.
  Future<WalletTopUp> cancelTopUp(String id) async {
    final response = await _session.post(
      'wallet/topups/${Uri.encodeComponent(id)}/cancel/',
      body: const {},
    );
    _ensure(response);
    final topUp = _map(response)['top_up'];
    return WalletTopUp.fromJson(
      topUp is Map<String, Object?> ? topUp : const {},
    );
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

  /// Moves [amount] dinars from the main wallet into the SMS balance. The
  /// same [idempotencyKey] sent again returns the first transfer.
  Future<WalletSmsAllocation> allocateToSms({
    required String amount,
    required String idempotencyKey,
  }) async {
    final response = await _session.post(
      'wallet/sms/allocations/',
      body: {'amount': amount, 'idempotency_key': idempotencyKey},
    );
    _ensure(response);
    return WalletSmsAllocation.fromJson(_map(response));
  }

  /// Moves [amount] dinars from the main wallet into the voucher balance the
  /// till's cards are paid from. The same [idempotencyKey] sent again returns
  /// the first transfer.
  Future<WalletVoucherAllocation> allocateToVouchers({
    required String amount,
    required String idempotencyKey,
  }) async {
    final response = await _session.post(
      'wallet/vouchers/allocations/',
      body: {'amount': amount, 'idempotency_key': idempotencyKey},
    );
    _ensure(response);
    return WalletVoucherAllocation.fromJson(_map(response));
  }

  /// Pays for [periods] periods of [plan] from the main wallet.
  Future<WalletPlanPurchase> purchasePlan({
    required String plan,
    required int periods,
    required String idempotencyKey,
  }) async {
    final response = await _session.post(
      'wallet/subscriptions/',
      body: {
        'plan': plan,
        'periods': periods,
        'idempotency_key': idempotencyKey,
      },
    );
    _ensure(response);
    return WalletPlanPurchase.fromJson(_map(response));
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
