part of 'wallet.dart';

/// The SMS balance: money the owner moved there from the main wallet, which
/// every text message is paid from.
class SmsWallet {
  const SmsWallet({
    required this.balance,
    required this.price,
    required this.messagesLeft,
    this.configured = true,
  });

  factory SmsWallet.fromJson(Map<String, Object?> json) {
    return SmsWallet(
      balance: _amount(json['balance']),
      price: _amount(json['price']),
      messagesLeft: _int(json['messages_left'], fallback: 0),
      configured: json['configured'] != false,
    );
  }

  /// Below zero only when a message went out longer than it was held for:
  /// the shop owes that, and the next transfer in pays it first.
  final double balance;

  /// What one SMS costs the shop. A text longer than one SMS (70 Arabic
  /// letters) goes out, and is paid, as several.
  final double price;

  /// How many SMS the balance pays for.
  final int messagesLeft;

  /// The company's SMS provider is set up; false means nobody can send yet.
  final bool configured;

  bool get canSend => configured && messagesLeft > 0;

  /// What the shop owes for messages that went out longer than they were
  /// held for; 0 when the balance is not below zero.
  double get owed => balance < 0 ? -balance : 0;

  /// How many messages [amount] dinars pay for.
  int messagesFor(double amount) {
    if (price <= 0 || amount <= 0) {
      return 0;
    }
    // In thousandths, so 0.3 / 0.15 is 2 and not 1.9999.
    return (amount * 1000).round() ~/ (price * 1000).round();
  }
}

/// A plan the shop pays for from its main wallet — remote access, or the
/// assistant — and where it stands.
class WalletPlan {
  const WalletPlan({
    required this.key,
    required this.available,
    required this.active,
    this.price,
    this.periodDays = 30,
    this.maxPeriods = 12,
    this.until,
    this.included = false,
  });

  factory WalletPlan.fromJson(Map<String, Object?> json) {
    return WalletPlan(
      key: _string(json['key']),
      available: json['available'] == true,
      active: json['active'] == true,
      price: _amountOrNull(json['price']),
      periodDays: _int(json['period_days'], fallback: 30),
      maxPeriods: _int(json['max_periods'], fallback: 12).clamp(1, 120),
      until: _date(json['until']),
      included: json['included'] == true,
    );
  }

  static const remoteAccess = 'remote_access';
  static const ai = 'ai';

  final String key;

  /// The wallet sells it right now: a price is set and the subscription does
  /// not already include it for good.
  final bool available;
  final bool active;

  /// One period's price; null when the wallet does not sell it.
  final double? price;
  final int periodDays;
  final int maxPeriods;

  /// When it stops; null when it is not running, or runs with no end.
  final DateTime? until;

  /// The subscription includes it with no end date: nothing to buy.
  final bool included;

  double priceFor(int periods) => (price ?? 0) * periods;

  /// When [periods] more periods bought [now] would end: they start where the
  /// plan's coverage ends, so renewing early loses nothing.
  DateTime endsAfter(int periods, DateTime now) {
    final current = until;
    final from = active && current != null && current.isAfter(now)
        ? current
        : now;
    return from.add(Duration(days: periodDays * periods));
  }
}

/// What moving money into the SMS balance came to.
class WalletSmsAllocation {
  const WalletSmsAllocation({
    required this.balance,
    required this.sms,
    required this.replayed,
  });

  factory WalletSmsAllocation.fromJson(Map<String, Object?> json) {
    final sms = json['sms'];
    return WalletSmsAllocation(
      balance: _amountOrNull(json['balance']),
      sms: sms is Map<String, Object?> ? SmsWallet.fromJson(sms) : null,
      replayed: json['replayed'] == true,
    );
  }

  /// The main wallet after the transfer.
  final double? balance;
  final SmsWallet? sms;
  final bool replayed;
}

/// What paying for a plan came to.
class WalletPlanPurchase {
  const WalletPlanPurchase({
    required this.plan,
    required this.balance,
    required this.replayed,
  });

  factory WalletPlanPurchase.fromJson(Map<String, Object?> json) {
    final plan = json['plan'];
    return WalletPlanPurchase(
      plan: plan is Map<String, Object?> ? WalletPlan.fromJson(plan) : null,
      balance: _amountOrNull(json['balance']),
      replayed: json['replayed'] == true,
    );
  }

  final WalletPlan? plan;

  /// The main wallet after the charge.
  final double? balance;
  final bool replayed;
}
