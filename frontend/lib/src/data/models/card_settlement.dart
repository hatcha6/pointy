import 'money_position.dart';

/// Card takings a processor (Moamalat) is holding, and the deposits that pay
/// them into the bank.
///
/// Money here is carried in whole **cents** parsed straight from the server's
/// strings. The settlement screen adds days up and subtracts the deposit from
/// them while the owner ticks boxes, and a difference that drifted by a
/// floating-point hair would be shown as a fee nobody charged.

/// The held days of one clearing account at a glance.
class HeldSummary {
  const HeldSummary({
    this.days = 0,
    this.payments = 0,
    this.oldestDay,
    this.nextExpectedOn,
    this.overdueDays = 0,
    this.overdueAmount = 0,
  });

  final int days;
  final int payments;
  final DateTime? oldestDay;
  final DateTime? nextExpectedOn;
  final int overdueDays;
  final double overdueAmount;

  bool get isEmpty => days == 0;
  bool get hasOverdue => overdueDays > 0;

  factory HeldSummary.fromJson(Map<String, Object?> json) {
    return HeldSummary(
      days: _int(json['days']),
      payments: _int(json['payments']),
      oldestDay: _date(json['oldest_day']),
      nextExpectedOn: _date(json['next_expected_on']),
      overdueDays: _int(json['overdue_days']),
      overdueAmount: centsToDouble(moneyCents(json['overdue_amount'])),
    );
  }
}

/// One processor day of held card takings.
class HeldDay {
  const HeldDay({
    required this.day,
    required this.expectedOn,
    required this.netCents,
    this.grossCents = 0,
    this.commissionCents = 0,
    this.count = 0,
    this.overdue = false,
  });

  final DateTime day;

  /// The day its money should reach the bank.
  final DateTime expectedOn;
  final bool overdue;
  final int grossCents;
  final int commissionCents;

  /// What the processor should pay for this day: the takings net of the fee
  /// estimated at each sale.
  final int netCents;
  final int count;

  String get key => isoDay(day);

  factory HeldDay.fromJson(Map<String, Object?> json) {
    return HeldDay(
      day: _date(json['day']) ?? DateTime(1970),
      expectedOn: _date(json['expected_on']) ?? DateTime(1970),
      overdue: json['overdue'] == true,
      grossCents: moneyCents(json['gross']),
      commissionCents: moneyCents(json['commission']),
      netCents: moneyCents(json['net']),
      count: _int(json['count']),
    );
  }
}

/// How sure the server is about the days it proposed for a deposit.
enum SettlementMatch {
  /// The deposit equals whole days, net of the estimated fee.
  exact('exact'),

  /// It equals them before the fee — the processor did not deduct one.
  gross('gross'),

  /// The oldest days come within a fee rounding of it.
  close('close'),

  /// Nothing adds up; the days that should have landed are proposed.
  due('due'),

  /// Nothing is due yet; the oldest held day is proposed.
  none('none');

  const SettlementMatch(this.apiValue);

  final String apiValue;

  static SettlementMatch fromApiValue(Object? value) {
    return SettlementMatch.values.firstWhere(
      (match) => match.apiValue == value?.toString(),
      orElse: () => SettlementMatch.none,
    );
  }
}

class SettlementSuggestion {
  const SettlementSuggestion({
    this.days = const [],
    this.match = SettlementMatch.none,
    this.expectedCents = 0,
    this.differenceCents,
  });

  final List<String> days;
  final SettlementMatch match;
  final int expectedCents;
  final int? differenceCents;

  factory SettlementSuggestion.fromJson(Map<String, Object?> json) {
    final rawDays = json['days'];
    return SettlementSuggestion(
      days: rawDays is List
          ? rawDays.map((day) => day.toString()).toList()
          : const [],
      match: SettlementMatch.fromApiValue(json['match']),
      expectedCents: moneyCents(json['expected']),
      differenceCents: json['difference'] == null
          ? null
          : moneyCents(json['difference']),
    );
  }
}

/// Everything a clearing account is holding, day by day, with a proposal for
/// which days a deposit paid.
class HeldTakings {
  const HeldTakings({
    required this.account,
    required this.days,
    required this.suggestion,
    this.today,
    this.settledOn,
    this.netCents = 0,
    this.overdueNetCents = 0,
    this.count = 0,
  });

  final MoneyAccount account;
  final List<HeldDay> days;
  final SettlementSuggestion suggestion;
  final DateTime? today;
  final DateTime? settledOn;
  final int netCents;
  final int overdueNetCents;
  final int count;

  bool get isEmpty => days.isEmpty;

  factory HeldTakings.fromJson(Map<String, Object?> json) {
    final rawDays = json['days'];
    final totals = (json['totals'] as Map?)?.cast<String, Object?>() ?? {};
    return HeldTakings(
      account: MoneyAccount.fromJson(
        (json['account'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      days: rawDays is List
          ? rawDays
                .whereType<Map>()
                .map((item) => HeldDay.fromJson(item.cast<String, Object?>()))
                .toList()
          : const [],
      suggestion: SettlementSuggestion.fromJson(
        (json['suggestion'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      today: _date(json['today']),
      settledOn: _date(json['settled_on']),
      netCents: moneyCents(totals['net']),
      overdueNetCents: moneyCents(totals['overdue_net']),
      count: _int(totals['count']),
    );
  }
}

/// One held card sale, with what its slip said.
class HeldPayment {
  const HeldPayment({
    required this.id,
    required this.netCents,
    this.orderId,
    this.invoiceNumber = '',
    this.paidAt,
    this.amountCents = 0,
    this.commissionCents = 0,
    this.reversesId,
    this.terminalId = '',
    this.maskedPan = '',
    this.batch = '',
  });

  final int id;
  final int? orderId;
  final String invoiceNumber;
  final DateTime? paidAt;
  final int amountCents;
  final int commissionCents;
  final int netCents;

  /// Set on a cancellation's counter row: the payment it gives back.
  final int? reversesId;
  final String terminalId;
  final String maskedPan;
  final String batch;

  bool get isReversal => reversesId != null;

  factory HeldPayment.fromJson(Map<String, Object?> json) {
    return HeldPayment(
      id: _int(json['id']),
      orderId: json['order_id'] == null ? null : _int(json['order_id']),
      invoiceNumber: json['invoice_number']?.toString() ?? '',
      paidAt: DateTime.tryParse(json['paid_at']?.toString() ?? '')?.toLocal(),
      amountCents: moneyCents(json['amount']),
      commissionCents: moneyCents(json['commission']),
      netCents: moneyCents(json['net']),
      reversesId: json['reverses_id'] == null
          ? null
          : _int(json['reverses_id']),
      terminalId: json['terminal_id']?.toString() ?? '',
      maskedPan: json['masked_pan']?.toString() ?? '',
      batch: json['batch']?.toString() ?? '',
    );
  }
}

/// A recorded deposit of held card takings.
class CardSettlement {
  const CardSettlement({
    required this.id,
    required this.settledOn,
    required this.amountReceivedCents,
    required this.expectedCents,
    required this.differenceCents,
    this.clearingAccountId,
    this.bankAccountName = '',
    this.paymentCount = 0,
    this.firstDay,
    this.lastDay,
    this.reference = '',
    this.note = '',
    this.createdByName = '',
    this.isCancelled = false,
    this.cancelReason = '',
  });

  final int id;
  final int? clearingAccountId;
  final String bankAccountName;
  final DateTime settledOn;
  final int amountReceivedCents;
  final int expectedCents;

  /// Received minus expected: negative when the processor kept more than the
  /// estimated fee.
  final int differenceCents;
  final int paymentCount;
  final DateTime? firstDay;
  final DateTime? lastDay;
  final String reference;
  final String note;
  final String createdByName;
  final bool isCancelled;
  final String cancelReason;

  factory CardSettlement.fromJson(Map<String, Object?> json) {
    return CardSettlement(
      id: _int(json['id']),
      clearingAccountId: json['clearing_account'] == null
          ? null
          : _int(json['clearing_account']),
      bankAccountName: json['bank_account_name']?.toString() ?? '',
      settledOn: _date(json['settled_on']) ?? DateTime(1970),
      amountReceivedCents: moneyCents(json['amount_received']),
      expectedCents: moneyCents(json['expected_amount']),
      differenceCents: moneyCents(json['difference']),
      paymentCount: _int(json['payment_count']),
      firstDay: _date(json['first_day']),
      lastDay: _date(json['last_day']),
      reference: json['reference']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
      createdByName: json['created_by_name']?.toString() ?? '',
      isCancelled: json['doc_status']?.toString() == 'cancelled',
      cancelReason: json['cancel_reason']?.toString() ?? '',
    );
  }
}

/// What the owner confirms: the deposit, and the held days it paid.
class CardSettlementDraft {
  const CardSettlementDraft({
    required this.clearingAccountId,
    required this.settledOn,
    required this.amountReceivedCents,
    required this.days,
    required this.expectedCents,
    this.excludePaymentIds = const [],
    this.reference = '',
    this.note = '',
  });

  final int clearingAccountId;
  final DateTime settledOn;
  final int amountReceivedCents;
  final List<String> days;

  /// Sales on the chosen days the processor did not include.
  final List<int> excludePaymentIds;

  /// The held total the owner saw. The server refuses the settlement if the
  /// takings changed since, rather than store it against another figure.
  final int expectedCents;
  final String reference;
  final String note;

  Map<String, Object?> toJson() {
    return {
      'clearing_account': clearingAccountId,
      'settled_on': isoDay(settledOn),
      'amount_received': centsToApi(amountReceivedCents),
      'days': days,
      if (excludePaymentIds.isNotEmpty)
        'exclude_payment_ids': excludePaymentIds,
      'expected_amount': centsToApi(expectedCents),
      'reference': reference,
      'note': note,
    };
  }
}

/// `2026-10-04`, the form every day travels in.
String isoDay(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

/// A money string or number as whole cents, exactly.
int moneyCents(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is int) {
    return value * 100;
  }
  if (value is num) {
    return (value * 100).round();
  }
  final text = value.toString().trim();
  final match = RegExp(r'^([+-]?)(\d*)(?:\.(\d{0,}))?$').firstMatch(text);
  if (match == null) {
    return 0;
  }
  final negative = match.group(1) == '-';
  final whole = int.tryParse(match.group(2) ?? '') ?? 0;
  final fraction = (match.group(3) ?? '').padRight(2, '0');
  final cents = int.tryParse(fraction.substring(0, 2)) ?? 0;
  // A third decimal rounds half up, like the server's quantize.
  final roundUp =
      fraction.length > 2 && (int.tryParse(fraction.substring(2, 3)) ?? 0) >= 5;
  final total = whole * 100 + cents + (roundUp ? 1 : 0);
  return negative ? -total : total;
}

String centsToApi(int cents) {
  final sign = cents < 0 ? '-' : '';
  final value = cents.abs();
  final whole = value ~/ 100;
  final fraction = (value % 100).toString().padLeft(2, '0');
  return '$sign$whole.$fraction';
}

double centsToDouble(int cents) => cents / 100;

DateTime? _date(Object? value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    return null;
  }
  return DateTime(parsed.year, parsed.month, parsed.day);
}

int _int(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
