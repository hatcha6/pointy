import 'dart:convert';

/// The shop's Daftar wallet: its prepaid balance with the company, topped up
/// through the payment gateway and drawn on by the company's services. The
/// relay holds the ledger; the shop's backend adds what only the shop knows —
/// who started a top-up and which expense it became.
class WalletOverview {
  const WalletOverview({
    required this.available,
    required this.balance,
    required this.currency,
    required this.testMode,
    required this.topUpOptions,
    required this.recentTopUps,
    required this.recentEntries,
    required this.settings,
    this.error,
  });

  factory WalletOverview.fromJson(Map<String, Object?> json) {
    final error = json['error'];
    final options = json['topups'];
    final settings = json['settings'];
    return WalletOverview(
      available: json['available'] == true,
      balance: _amountOrNull(json['balance']),
      currency: _string(json['currency'], fallback: 'LYD'),
      testMode: json['test_mode'] == true,
      topUpOptions: options is Map<String, Object?>
          ? WalletTopUpOptions.fromJson(options)
          : null,
      recentTopUps: _list(json['recent_topups'], WalletTopUp.fromJson),
      recentEntries: _list(json['recent_entries'], WalletEntry.fromJson),
      settings: settings is Map<String, Object?>
          ? WalletSettings.fromJson(settings)
          : const WalletSettings(recordTopUpsAsExpenses: true),
      error: error is Map<String, Object?>
          ? WalletError(
              code: _string(error['code']),
              message: _string(error['detail']),
            )
          : null,
    );
  }

  /// False when the relay could not be read; [error] says why, and
  /// [recentTopUps] is then the shop's own copy.
  final bool available;

  /// Null while it cannot be read.
  final double? balance;
  final String currency;

  /// Top-ups are Plutu test payments: no real money moves.
  final bool testMode;
  final WalletTopUpOptions? topUpOptions;
  final List<WalletTopUp> recentTopUps;
  final List<WalletEntry> recentEntries;
  final WalletSettings settings;
  final WalletError? error;

  bool get canTopUp =>
      available &&
      (topUpOptions?.available ?? false) &&
      (topUpOptions?.methods.isNotEmpty ?? false);

  WalletOverview copyWith({WalletSettings? settings}) {
    return WalletOverview(
      available: available,
      balance: balance,
      currency: currency,
      testMode: testMode,
      topUpOptions: topUpOptions,
      recentTopUps: recentTopUps,
      recentEntries: recentEntries,
      settings: settings ?? this.settings,
      error: error,
    );
  }
}

/// What a top-up may be right now.
class WalletTopUpOptions {
  const WalletTopUpOptions({
    required this.available,
    required this.methods,
    required this.minAmount,
    required this.maxAmount,
    required this.maxDecimals,
    required this.quickAmounts,
    required this.pendingTtl,
  });

  factory WalletTopUpOptions.fromJson(Map<String, Object?> json) {
    final quick = json['quick_amounts'];
    return WalletTopUpOptions(
      available: json['available'] == true,
      methods: _list(json['methods'], WalletTopUpMethod.fromJson),
      minAmount: _amount(json['min_amount']),
      maxAmount: _amount(json['max_amount']),
      maxDecimals: _int(json['max_decimals'], fallback: 2),
      quickAmounts: quick is List
          ? quick.map(_amount).where((value) => value > 0).toList()
          : const [],
      pendingTtl: Duration(seconds: _int(json['pending_ttl'], fallback: 1800)),
    );
  }

  final bool available;
  final List<WalletTopUpMethod> methods;
  final double minAmount;
  final double maxAmount;
  final int maxDecimals;
  final List<double> quickAmounts;

  /// How long a checkout stays open before the relay writes it off.
  final Duration pendingTtl;
}

/// One way to pay in. Only Plutu's local bank cards today.
class WalletTopUpMethod {
  const WalletTopUpMethod({
    required this.key,
    required this.gateway,
    required this.kind,
  });

  factory WalletTopUpMethod.fromJson(Map<String, Object?> json) {
    return WalletTopUpMethod(
      key: _string(json['key']),
      gateway: _string(json['gateway']),
      kind: _string(json['kind']),
    );
  }

  static const localBankCards = 'plutu_localbankcards';

  final String key;
  final String gateway;

  /// `hosted_checkout`: the payer pays on the gateway's own page.
  final String kind;
}

enum WalletTopUpStatus {
  pending,
  paid,
  canceled,
  failed,
  expired,
  unknown;

  static WalletTopUpStatus parse(Object? raw) {
    return switch (raw) {
      'pending' => pending,
      'paid' => paid,
      'canceled' => canceled,
      'failed' => failed,
      'expired' => expired,
      _ => unknown,
    };
  }

  /// The relay can still move it: a checkout can be paid late.
  bool get isOpen => this == pending || this == expired;
}

class WalletTopUp {
  const WalletTopUp({
    required this.id,
    required this.invoiceNo,
    required this.method,
    required this.amount,
    required this.status,
    required this.testMode,
    required this.createdAt,
    this.requestedBy = '',
    this.providerTransactionId = '',
    this.errorCode = '',
    this.confirmedBy = '',
    this.paidAt,
    this.checkoutUrl,
    this.recordAsExpense,
    this.expenseId,
    this.expenseError = '',
  });

  factory WalletTopUp.fromJson(Map<String, Object?> json) {
    final expenseId = json['expense_id'];
    final record = json['record_as_expense'];
    final checkout = _string(json['checkout_url']);
    return WalletTopUp(
      id: _string(json['id']),
      invoiceNo: _string(json['invoice_no']),
      method: _string(json['method']),
      amount: _amount(json['amount']),
      status: WalletTopUpStatus.parse(json['status']),
      testMode: json['test_mode'] == true,
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      requestedBy: _string(json['requested_by']),
      providerTransactionId: _string(json['provider_transaction_id']),
      errorCode: _string(json['error_code']),
      confirmedBy: _string(json['confirmed_by']),
      paidAt: _date(json['paid_at']),
      checkoutUrl: checkout.isEmpty ? null : checkout,
      recordAsExpense: record is bool ? record : null,
      expenseId: expenseId is num ? expenseId.toInt() : null,
      expenseError: _string(json['expense_error']),
    );
  }

  final String id;

  /// The reference support and the gateway's dashboard share, DFW-XXXXXXXXXX.
  final String invoiceNo;
  final String method;
  final double amount;
  final WalletTopUpStatus status;
  final bool testMode;
  final DateTime createdAt;
  final String requestedBy;
  final String providerTransactionId;
  final String errorCode;

  /// `plutu` for the gateway's signed return, `operator:<name>` when the
  /// company reconciled it by hand.
  final String confirmedBy;
  final DateTime? paidAt;

  /// The checkout page, only while it can still be paid.
  final String? checkoutUrl;

  /// Whether the shop asked for this top-up in its books; null when the shop
  /// did not start it from here.
  final bool? recordAsExpense;
  final int? expenseId;

  /// Why booking the expense failed (a closed period), when it did.
  final String expenseError;

  bool get isBookedAsExpense => expenseId != null;
}

enum WalletEntryKind {
  topUp,
  charge,
  refund,
  adjustment,
  unknown;

  static WalletEntryKind parse(Object? raw) {
    return switch (raw) {
      'topup' => topUp,
      'charge' => charge,
      'refund' => refund,
      'adjustment' => adjustment,
      _ => unknown,
    };
  }
}

/// One movement of the balance.
class WalletEntry {
  const WalletEntry({
    required this.id,
    required this.kind,
    required this.amount,
    required this.balanceAfter,
    required this.createdAt,
    this.service = '',
    this.reference = '',
    this.description = '',
    this.testMode = false,
  });

  factory WalletEntry.fromJson(Map<String, Object?> json) {
    return WalletEntry(
      id: _string(json['id']),
      kind: WalletEntryKind.parse(json['kind']),
      amount: _amount(json['amount']),
      balanceAfter: _amount(json['balance_after']),
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      service: _string(json['service']),
      reference: _string(json['reference']),
      description: _string(json['description']),
      testMode: json['test_mode'] == true,
    );
  }

  final String id;
  final WalletEntryKind kind;

  /// Signed: positive credits the wallet, negative debits it.
  final double amount;
  final double balanceAfter;
  final DateTime createdAt;

  /// What a charge or refund was for: subscription, sms, ai, vouchers, ...
  final String service;
  final String reference;
  final String description;
  final bool testMode;
}

class WalletSettings {
  const WalletSettings({
    required this.recordTopUpsAsExpenses,
    this.expenseCategoryId,
    this.expenseCategoryName,
    this.defaultExpenseCategoryName = '',
  });

  factory WalletSettings.fromJson(Map<String, Object?> json) {
    final category = json['expense_category'];
    return WalletSettings(
      recordTopUpsAsExpenses: json['record_topups_as_expenses'] != false,
      expenseCategoryId: category is Map<String, Object?>
          ? (category['id'] as num?)?.toInt()
          : null,
      expenseCategoryName: category is Map<String, Object?>
          ? _string(category['name'])
          : null,
      defaultExpenseCategoryName: _string(
        json['default_expense_category_name'],
      ),
    );
  }

  final bool recordTopUpsAsExpenses;
  final int? expenseCategoryId;
  final String? expenseCategoryName;
  final String defaultExpenseCategoryName;

  /// The category a top-up lands in: the owner's pick, else the default.
  String get effectiveCategoryName {
    final chosen = expenseCategoryName?.trim() ?? '';
    return chosen.isNotEmpty ? chosen : defaultExpenseCategoryName;
  }
}

/// A started top-up and the page to pay it on.
class WalletTopUpStart {
  const WalletTopUpStart({
    required this.topUp,
    required this.checkoutUrl,
    required this.replayed,
  });

  factory WalletTopUpStart.fromJson(Map<String, Object?> json) {
    final topUp = json['top_up'];
    return WalletTopUpStart(
      topUp: WalletTopUp.fromJson(
        topUp is Map<String, Object?> ? topUp : const {},
      ),
      checkoutUrl: _string(json['checkout_url']),
      replayed: json['replayed'] == true,
    );
  }

  final WalletTopUp topUp;
  final String checkoutUrl;
  final bool replayed;
}

class WalletPage<T> {
  const WalletPage({required this.items, required this.hasMore});

  final List<T> items;
  final bool hasMore;
}

/// Why the wallet could not be read, as the backend coded it.
class WalletError {
  const WalletError({required this.code, required this.message});

  final String code;

  /// The backend's Arabic sentence, shown when the app has none of its own.
  final String message;
}

/// A wallet call the backend refused, with its code and, for a top-up, the
/// amount bounds and the failed top-up it recorded.
class WalletException implements Exception {
  const WalletException({
    required this.code,
    required this.message,
    this.statusCode,
    this.minAmount,
    this.maxAmount,
    this.topUp,
  });

  factory WalletException.fromResponse(int statusCode, String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map<String, Object?>) {
      return WalletException(
        code: statusCode == 403 ? 'forbidden' : 'unexpected',
        message: '',
        statusCode: statusCode,
      );
    }
    final topUp = decoded['top_up'];
    var code = _string(decoded['code']);
    if (code.isEmpty) {
      // A DRF validation error ({"amount": ["..."]}) or a 403.
      code = statusCode == 403
          ? 'forbidden'
          : (statusCode == 400 ? 'invalid_amount' : 'unexpected');
    }
    return WalletException(
      code: code,
      message: _string(decoded['detail']),
      statusCode: statusCode,
      minAmount: _amountOrNull(decoded['min_amount']),
      maxAmount: _amountOrNull(decoded['max_amount']),
      topUp: topUp is Map<String, Object?> ? WalletTopUp.fromJson(topUp) : null,
    );
  }

  final String code;
  final String message;
  final int? statusCode;
  final double? minAmount;
  final double? maxAmount;
  final WalletTopUp? topUp;

  /// A retry of the same attempt may still work (the network, a busy gateway).
  bool get isRetryable => const {
    'relay_unreachable',
    'gateway_busy',
    'rate_limited',
    'in_flight',
    'network',
  }.contains(code);

  @override
  String toString() =>
      'WalletException($code${message.isEmpty ? '' : ': $message'})';
}

List<T> _list<T>(Object? raw, T Function(Map<String, Object?>) parse) {
  if (raw is! List) {
    return const [];
  }
  return raw.whereType<Map<String, Object?>>().map(parse).toList();
}

String _string(Object? raw, {String fallback = ''}) {
  if (raw == null) {
    return fallback;
  }
  final value = raw.toString().trim();
  return value.isEmpty ? fallback : value;
}

double _amount(Object? raw) => _amountOrNull(raw) ?? 0;

double? _amountOrNull(Object? raw) {
  if (raw is num) {
    return raw.toDouble();
  }
  if (raw is String) {
    return double.tryParse(raw.trim());
  }
  return null;
}

int _int(Object? raw, {required int fallback}) {
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw) ?? fallback;
  }
  return fallback;
}

DateTime? _date(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw)?.toLocal();
}
