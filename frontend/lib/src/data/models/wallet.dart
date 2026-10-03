import 'dart:convert';

part 'wallet_spending.dart';

/// The shop's Daftar wallet: its prepaid balance with the company, topped up
/// through the payment gateway and drawn on by the company's services. The
/// relay holds the ledger; the shop's backend adds what only the shop knows —
/// who started a top-up and which expense it became.
///
/// The money sits in two places: the main wallet, which top-ups credit and
/// the plans are paid from, and the [sms] balance each message is paid from.
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
    this.sms,
    this.plans = const [],
    this.error,
  });

  factory WalletOverview.fromJson(Map<String, Object?> json) {
    final error = json['error'];
    final options = json['topups'];
    final settings = json['settings'];
    final sms = json['sms'];
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
      sms: sms is Map<String, Object?> ? SmsWallet.fromJson(sms) : null,
      plans: _list(
        json['plans'],
        WalletPlan.fromJson,
      ).where((plan) => plan.key.isNotEmpty).toList(),
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

  /// Top-ups are the gateway's test payments: no real money moves.
  final bool testMode;
  final WalletTopUpOptions? topUpOptions;
  final List<WalletTopUp> recentTopUps;
  final List<WalletEntry> recentEntries;
  final WalletSettings settings;

  /// The SMS balance; null from a relay that does not sell SMS by the message.
  final SmsWallet? sms;

  /// The plans the wallet pays for, in the order the app shows them.
  final List<WalletPlan> plans;
  final WalletError? error;

  bool get canTopUp =>
      available &&
      (topUpOptions?.available ?? false) &&
      (topUpOptions?.methods.isNotEmpty ?? false);

  WalletPlan? planFor(String key) {
    for (final plan in plans) {
      if (plan.key == key) {
        return plan;
      }
    }
    return null;
  }

  WalletOverview copyWith({
    WalletSettings? settings,
    double? balance,
    SmsWallet? sms,
    WalletPlan? plan,
  }) {
    return WalletOverview(
      available: available,
      balance: balance ?? this.balance,
      currency: currency,
      testMode: testMode,
      topUpOptions: topUpOptions,
      recentTopUps: recentTopUps,
      recentEntries: recentEntries,
      settings: settings ?? this.settings,
      sms: sms ?? this.sms,
      plans: plan == null
          ? plans
          : [for (final known in plans) known.key == plan.key ? plan : known],
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
    this.maxOtpAttempts = 5,
  });

  factory WalletTopUpOptions.fromJson(Map<String, Object?> json) {
    final quick = json['quick_amounts'];
    return WalletTopUpOptions(
      available: json['available'] == true,
      methods: _list(
        json['methods'],
        WalletTopUpMethod.fromJson,
      ).where((method) => method.key.isNotEmpty).toList(),
      minAmount: _amount(json['min_amount']),
      maxAmount: _amount(json['max_amount']),
      maxDecimals: _int(json['max_decimals'], fallback: 2).clamp(0, 3),
      quickAmounts: quick is List
          ? quick.map(_amount).where((value) => value > 0).toList()
          : const [],
      pendingTtl: Duration(seconds: _int(json['pending_ttl'], fallback: 1800)),
      maxOtpAttempts: _int(json['max_otp_attempts'], fallback: 5),
    );
  }

  final bool available;

  /// In the order the company offers them.
  final List<WalletTopUpMethod> methods;
  final double minAmount;
  final double maxAmount;
  final int maxDecimals;
  final List<double> quickAmounts;

  /// How long a top-up stays open before the relay writes it off.
  final Duration pendingTtl;

  /// Codes the payer may try on one top-up.
  final int maxOtpAttempts;
}

/// What a method asks of the payer before the payment starts.
enum WalletPayer {
  /// Bank cards: the payer types the card on the gateway's own page.
  none,

  /// The mobile number the payer's wallet is registered to.
  phone,

  /// The payer's wallet card number.
  card;

  static WalletPayer parse(Object? raw) {
    return switch (raw) {
      'phone' => phone,
      'card' => card,
      _ => none,
    };
  }
}

/// The payer's details read the way the relay reads them, so the owner hears
/// about a mistyped number at once instead of after a round trip. The relay
/// checks again; these only spare the trip.
abstract final class WalletPayerRules {
  /// A Libyan mobile number as people write it — 0912345678, +218 91 234
  /// 5678, Arabic-Indic digits — as its nine digits, or null.
  static String? phone(String raw) {
    var digits = _digits(raw);
    if (digits == null) {
      return null;
    }
    digits = digits.startsWith('+') ? digits.substring(1) : digits;
    if (digits.startsWith('00218')) {
      digits = digits.substring(5);
    } else if (digits.startsWith('218') && digits.length == 12) {
      digits = digits.substring(3);
    } else if (digits.startsWith('0') && digits.length == 10) {
      digits = digits.substring(1);
    }
    return digits.length == 9 && digits.startsWith('9') ? digits : null;
  }

  /// A wallet card number: 6 to 19 digits once spaces and dashes are gone.
  static String? card(String raw) {
    final digits = _digits(raw);
    if (digits == null ||
        digits.startsWith('+') ||
        digits.length < 6 ||
        digits.length > 19) {
      return null;
    }
    return digits;
  }

  /// A one-time code: 4 to 8 digits.
  static String? code(String raw) {
    final digits = _digits(raw);
    if (digits == null ||
        digits.startsWith('+') ||
        digits.length < 4 ||
        digits.length > 8) {
      return null;
    }
    return digits;
  }

  /// A four-digit year of birth no later than [now]'s.
  static String? birthYear(String raw, DateTime now) {
    final digits = _digits(raw);
    final year = digits == null ? null : int.tryParse(digits);
    if (digits == null || digits.length != 4 || year == null) {
      return null;
    }
    return year >= 1900 && year <= now.year ? digits : null;
  }

  /// [raw] with Arabic-Indic digits made ASCII and spaces, dashes, dots and
  /// direction marks dropped; null if anything else is left. A leading + is
  /// kept for the caller to read.
  static String? _digits(String raw) {
    final buffer = StringBuffer();
    final text = raw.trim();
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit >= 0x30 && unit <= 0x39) {
        buffer.writeCharCode(unit);
      } else if (unit >= 0x0660 && unit <= 0x0669) {
        buffer.writeCharCode(0x30 + unit - 0x0660);
      } else if (unit >= 0x06F0 && unit <= 0x06F9) {
        buffer.writeCharCode(0x30 + unit - 0x06F0);
      } else if (unit == 0x2B && index == 0) {
        buffer.write('+');
      } else if (!' -.()\u00A0\u200E\u200F'.contains(text[index])) {
        return null;
      }
    }
    return buffer.toString();
  }
}

/// One way to pay in, through the Dafa gateway: local bank cards on Dafa's
/// page, or a mobile wallet (Sadad, Edfali, MobiCash, Yussor/Masrafi/Sahara
/// Pay) confirmed with the code its provider texts the payer.
class WalletTopUpMethod {
  const WalletTopUpMethod({
    required this.key,
    required this.gateway,
    required this.kind,
    this.provider = '',
    this.payer = WalletPayer.none,
    this.needsBirthYear = false,
  });

  factory WalletTopUpMethod.fromJson(Map<String, Object?> json) {
    return WalletTopUpMethod(
      key: _string(json['key']),
      gateway: _string(json['gateway']),
      kind: _string(json['kind']),
      provider: _string(json['provider']),
      payer: WalletPayer.parse(json['payer']),
      needsBirthYear: json['birth_year'] == true,
    );
  }

  static const bankCards = 'dafa_moamalat';

  /// Plutu's card checkout, which Dafa replaced. Old top-ups keep the name,
  /// and a relay not yet moved to Dafa still offers it.
  static const legacyBankCards = 'plutu_localbankcards';

  static const kindOtp = 'otp';
  static const kindHostedPage = 'hosted_page';

  final String key;
  final String gateway;

  /// `otp` or `hosted_page` (`hosted_checkout` from a relay before Dafa).
  final String kind;

  /// The gateway's own name for it — `sadad`, `yussor-pay` — which names its
  /// mark in assets/payment_methods/.
  final String provider;
  final WalletPayer payer;

  /// Sadad also asks for the payer's year of birth.
  final bool needsBirthYear;

  /// The payer confirms with a code texted to them.
  bool get confirmsWithCode => kind == kindOtp;
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
    this.kind = '',
    this.payerHint = '',
    this.requestedBy = '',
    this.providerTransactionId = '',
    this.errorCode = '',
    this.confirmedBy = '',
    this.paidAt,
    this.checkoutUrl,
    this.otpAttemptsLeft,
    this.recordAsExpense,
    this.expenseId,
    this.expenseError = '',
  });

  factory WalletTopUp.fromJson(Map<String, Object?> json) {
    final expenseId = json['expense_id'];
    final record = json['record_as_expense'];
    final checkout = _string(json['checkout_url']);
    final attemptsLeft = json['otp_attempts_left'];
    return WalletTopUp(
      id: _string(json['id']),
      invoiceNo: _string(json['invoice_no']),
      method: _string(json['method']),
      amount: _amount(json['amount']),
      status: WalletTopUpStatus.parse(json['status']),
      testMode: json['test_mode'] == true,
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      kind: _string(json['kind']),
      payerHint: _string(json['payer_hint']),
      requestedBy: _string(json['requested_by']),
      providerTransactionId: _string(json['provider_transaction_id']),
      errorCode: _string(json['error_code']),
      confirmedBy: _string(json['confirmed_by']),
      paidAt: _date(json['paid_at']),
      checkoutUrl: checkout.isEmpty ? null : checkout,
      otpAttemptsLeft: attemptsLeft is num ? attemptsLeft.toInt() : null,
      recordAsExpense: record is bool ? record : null,
      expenseId: expenseId is num ? expenseId.toInt() : null,
      expenseError: _string(json['expense_error']),
    );
  }

  final String id;

  /// The company's own reference, DFW-XXXXXXXXXX, what the owner reads to
  /// support.
  final String invoiceNo;
  final String method;

  /// `otp` or `hosted_page`: what the payer does to finish it.
  final String kind;

  /// The payer's phone or card, masked by the relay: "091•••678".
  final String payerHint;
  final double amount;
  final WalletTopUpStatus status;
  final bool testMode;
  final DateTime createdAt;
  final String requestedBy;
  final String providerTransactionId;
  final String errorCode;

  /// `dafa` for the gateway's own answer, `operator:<name>` when the company
  /// reconciled it by hand.
  final String confirmedBy;
  final DateTime? paidAt;

  /// The gateway's payment page, only while a bank card can still pay it.
  final String? checkoutUrl;

  /// Codes left to try, while a code can still be sent.
  final int? otpAttemptsLeft;

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

  /// The shop moving its own money between its accounts: out of the main
  /// wallet and into the SMS balance.
  transfer,
  unknown;

  static WalletEntryKind parse(Object? raw) {
    return switch (raw) {
      'topup' => topUp,
      'charge' => charge,
      'refund' => refund,
      'adjustment' => adjustment,
      'transfer' => transfer,
      _ => unknown,
    };
  }
}

/// Where money sits: the main wallet, or the SMS balance.
enum WalletAccount {
  main('main'),
  sms('sms');

  const WalletAccount(this.key);

  final String key;

  static WalletAccount parse(Object? raw) => raw == 'sms' ? sms : main;
}

/// One movement of the balance.
class WalletEntry {
  const WalletEntry({
    required this.id,
    required this.kind,
    required this.amount,
    required this.balanceAfter,
    required this.createdAt,
    this.account = WalletAccount.main,
    this.service = '',
    this.reference = '',
    this.description = '',
    this.testMode = false,
  });

  factory WalletEntry.fromJson(Map<String, Object?> json) {
    return WalletEntry(
      id: _string(json['id']),
      account: WalletAccount.parse(json['account']),
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
  final WalletAccount account;
  final WalletEntryKind kind;

  /// Signed: positive credits the wallet, negative debits it.
  final double amount;
  final double balanceAfter;
  final DateTime createdAt;

  /// What a charge or refund was for: remote_access, ai, sms, vouchers, ...
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

/// A started top-up and what the payer does next.
class WalletTopUpStart {
  const WalletTopUpStart({
    required this.topUp,
    required this.checkoutUrl,
    required this.replayed,
    this.nextAction = '',
  });

  factory WalletTopUpStart.fromJson(Map<String, Object?> json) {
    final topUp = json['top_up'];
    return WalletTopUpStart(
      topUp: WalletTopUp.fromJson(
        topUp is Map<String, Object?> ? topUp : const {},
      ),
      checkoutUrl: _string(json['checkout_url']),
      replayed: json['replayed'] == true,
      nextAction: _string(json['next_action']),
    );
  }

  final WalletTopUp topUp;

  /// The gateway's page, for a bank card.
  final String checkoutUrl;
  final bool replayed;

  /// `otp`: type the code the provider texted. Anything else: the payer pays
  /// on [checkoutUrl].
  final String nextAction;

  bool get needsCode =>
      (nextAction.isEmpty ? topUp.kind : nextAction) ==
      WalletTopUpMethod.kindOtp;
}

/// What sending a code came to: the top-up as it now stands, and whether the
/// gateway took the code without a verdict yet (then the app keeps asking).
class WalletTopUpConfirmation {
  const WalletTopUpConfirmation({
    required this.topUp,
    required this.awaitingGateway,
  });

  factory WalletTopUpConfirmation.fromJson(Map<String, Object?> json) {
    final topUp = json['top_up'];
    return WalletTopUpConfirmation(
      topUp: WalletTopUp.fromJson(
        topUp is Map<String, Object?> ? topUp : const {},
      ),
      awaitingGateway: json['code'] == 'awaiting_gateway',
    );
  }

  final WalletTopUp topUp;
  final bool awaitingGateway;
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
    this.gatewayCode = '',
    this.gatewayMessage = '',
    this.attemptsLeft,
    this.balance,
    this.amount,
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
    final attemptsLeft = decoded['attempts_left'];
    return WalletException(
      code: code,
      message: _string(decoded['detail']),
      statusCode: statusCode,
      minAmount: _amountOrNull(decoded['min_amount']),
      maxAmount: _amountOrNull(decoded['max_amount']),
      topUp: topUp is Map<String, Object?> ? WalletTopUp.fromJson(topUp) : null,
      gatewayCode: _string(decoded['gateway_code']),
      gatewayMessage: _string(decoded['gateway_message']),
      attemptsLeft: attemptsLeft is num ? attemptsLeft.toInt() : null,
      balance: _amountOrNull(decoded['balance']),
      amount: _amountOrNull(decoded['amount']),
    );
  }

  final String code;
  final String message;
  final int? statusCode;
  final double? minAmount;
  final double? maxAmount;
  final WalletTopUp? topUp;

  /// The gateway's own code for a refused payment: PAYER_OTP_WRONG,
  /// PAYER_INSUFFICIENT_FUNDS, ...
  final String gatewayCode;

  /// The gateway's own sentence about it, written for the payer.
  final String gatewayMessage;

  /// Codes left after a wrong one.
  final int? attemptsLeft;

  /// For a spend the wallet could not cover: what it holds, and what was asked.
  final double? balance;
  final double? amount;

  /// A retry of the same attempt may still work (the network, a busy gateway).
  bool get isRetryable => const {
    'relay_unreachable',
    'gateway_busy',
    'rate_limited',
    'in_flight',
    'network',
  }.contains(code);

  /// Refusals that leave a code-confirmed top-up open: the payer may type
  /// the code (again).
  bool get leavesCodeOpen => const {
    'otp_rejected',
    'invalid_otp',
    'confirm_unknown',
    'gateway_busy',
    'relay_unreachable',
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
