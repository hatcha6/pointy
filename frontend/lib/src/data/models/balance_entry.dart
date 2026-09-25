/// Opening balances and adjustments on a customer's or a supplier's account —
/// the debts no invoice or purchase order could carry. Mirrors
/// `apps.balances` on the server.
library;

/// Which way a balance runs, from the shop's side: the way an owner says it,
/// "عليه لنا" or "له علينا", rather than debit and credit, which flip meaning
/// between a customer's account and a supplier's.
enum BalanceDirection {
  theyOweUs('they_owe_us'),
  weOweThem('we_owe_them');

  const BalanceDirection(this.apiValue);

  final String apiValue;

  static BalanceDirection fromApi(String? value) {
    return BalanceDirection.values.firstWhere(
      (direction) => direction.apiValue == value,
      orElse: () => BalanceDirection.theyOweUs,
    );
  }
}

enum BalanceEntryKind {
  /// Where the account stood the day the shop started keeping it here. At
  /// most one live one per account.
  opening('opening'),

  /// A later correction for something no invoice could carry.
  adjustment('adjustment'),

  /// A balance settled with cash through the drawer: the shop paying a
  /// customer the credit it held for them, or a supplier paying back what
  /// they owed. Final once made.
  refund('refund');

  const BalanceEntryKind(this.apiValue);

  final String apiValue;

  static BalanceEntryKind fromApi(String? value) {
    return BalanceEntryKind.values.firstWhere(
      (kind) => kind.apiValue == value,
      orElse: () => BalanceEntryKind.adjustment,
    );
  }
}

/// Whose account an entry sits on — it decides which endpoint carries it.
enum BalanceParty {
  customer('customer', 'customer-balance-entries/'),
  supplier('supplier', 'supplier-balance-entries/');

  const BalanceParty(this.fieldName, this.path);

  /// The field naming the party in the entry payload.
  final String fieldName;
  final String path;
}

class BalanceEntry {
  const BalanceEntry({
    required this.id,
    required this.number,
    required this.kind,
    required this.direction,
    required this.amount,
    required this.settledAmount,
    required this.remainingAmount,
    this.effectiveDate,
    this.note = '',
    this.createdByUsername = '',
    this.createdAt,
    this.canCancel = false,
    this.isCancelled = false,
    this.cancelReason = '',
    this.cancelledAt,
    this.cancelledByUsername = '',
  });

  final int id;
  final String number;
  final BalanceEntryKind kind;
  final BalanceDirection direction;
  final double amount;

  /// How much of it has been collected, paid or spent.
  final double settledAmount;
  final double remainingAmount;
  final DateTime? effectiveDate;
  final String note;
  final String createdByUsername;
  final DateTime? createdAt;

  /// Whether it can still be withdrawn: only while nothing has been settled
  /// against it. The server decides; the client only offers.
  final bool canCancel;
  final bool isCancelled;
  final String cancelReason;
  final DateTime? cancelledAt;
  final String cancelledByUsername;

  bool get isOpening => kind == BalanceEntryKind.opening;
  bool get isRefund => kind == BalanceEntryKind.refund;

  factory BalanceEntry.fromJson(Map<String, Object?> json) {
    return BalanceEntry(
      id: _intFromJson(json['id']),
      number: json['number']?.toString() ?? '',
      kind: BalanceEntryKind.fromApi(json['kind']?.toString()),
      direction: BalanceDirection.fromApi(json['direction']?.toString()),
      amount: _moneyFromJson(json['amount']),
      settledAmount: _moneyFromJson(json['settled_amount']),
      remainingAmount: _moneyFromJson(json['remaining_amount']),
      effectiveDate: _dateFromJson(json['effective_date']),
      note: json['note']?.toString() ?? '',
      createdByUsername: json['created_by_username']?.toString() ?? '',
      createdAt: _dateFromJson(json['created_at']),
      canCancel: json['can_cancel'] == true,
      isCancelled: json['doc_status']?.toString() == 'cancelled',
      cancelReason: json['cancel_reason']?.toString() ?? '',
      cancelledAt: _dateFromJson(json['cancelled_at']),
      cancelledByUsername: json['cancelled_by_username']?.toString() ?? '',
    );
  }
}

class BalanceEntryPage {
  const BalanceEntryPage({required this.entries, required this.hasMore});

  final List<BalanceEntry> entries;
  final bool hasMore;

  factory BalanceEntryPage.fromAny(Object? json) {
    if (json is List) {
      return BalanceEntryPage(
        entries: json
            .whereType<Map<String, Object?>>()
            .map(BalanceEntry.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    final map = json is Map<String, Object?> ? json : const <String, Object?>{};
    return BalanceEntryPage(
      entries: (map['results'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(BalanceEntry.fromJson)
          .toList(growable: false),
      hasMore: map['next'] != null,
    );
  }
}

/// One opening balance or adjustment, as it is typed in.
class BalanceEntryDraft {
  const BalanceEntryDraft({
    required this.kind,
    required this.direction,
    required this.amount,
    this.note = '',
    this.effectiveDate,
  });

  final BalanceEntryKind kind;
  final BalanceDirection direction;
  final double amount;
  final String note;

  /// The day it applies from; null means today.
  final DateTime? effectiveDate;

  Map<String, Object?> toJson() {
    return {
      'kind': kind.apiValue,
      'direction': direction.apiValue,
      'amount': amount.toStringAsFixed(2),
      if (note.trim().isNotEmpty) 'note': note.trim(),
      if (effectiveDate != null)
        'effective_date': effectiveDate!.toIso8601String().split('T').first,
    };
  }
}

/// The opening balance a new customer or supplier arrives with, written in
/// the same request (and the same server transaction) that creates them.
class OpeningBalanceDraft {
  const OpeningBalanceDraft({
    required this.direction,
    required this.amount,
    this.note = '',
    this.effectiveDate,
  });

  final BalanceDirection direction;
  final double amount;
  final String note;
  final DateTime? effectiveDate;

  Map<String, Object?> toJson() {
    return {
      'direction': direction.apiValue,
      'amount': amount.toStringAsFixed(2),
      if (note.trim().isNotEmpty) 'note': note.trim(),
      if (effectiveDate != null)
        'effective_date': effectiveDate!.toIso8601String().split('T').first,
    };
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

DateTime? _dateFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
