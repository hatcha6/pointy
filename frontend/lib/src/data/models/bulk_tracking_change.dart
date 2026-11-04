/// Moving products onto expiry tracking in bulk — see
/// `POST bulk-tracking-changes/preview/` and `.../apply/`.
library;

import '../../shared/date_formatters.dart';

int _int(Object? raw) => switch (raw) {
  int value => value,
  num value => value.toInt(),
  String value => int.tryParse(value) ?? 0,
  _ => 0,
};

double _decimal(Object? raw) => switch (raw) {
  num value => value.toDouble(),
  String value => double.tryParse(value) ?? 0,
  _ => 0,
};

/// Where the products' tracking should end up.
enum BulkTrackingTarget {
  keep('keep'),
  expiry('expiry'),
  lots('lots');

  const BulkTrackingTarget(this.apiValue);
  final String apiValue;
}

enum BulkReminderMode {
  keep('keep'),
  set('set'),
  clear('clear');

  const BulkReminderMode(this.apiValue);
  final String apiValue;
}

/// What the owner asked for, without the scope: [toJson] adds that.
class BulkTrackingAction {
  const BulkTrackingAction({
    this.tracking = BulkTrackingTarget.keep,
    this.reminderMode = BulkReminderMode.keep,
    this.reminderDate,
  });

  final BulkTrackingTarget tracking;
  final BulkReminderMode reminderMode;
  final DateTime? reminderDate;

  /// The server refuses a request that changes nothing.
  bool get isNoop =>
      tracking == BulkTrackingTarget.keep &&
      reminderMode == BulkReminderMode.keep;

  bool get isComplete =>
      !isNoop && (reminderMode != BulkReminderMode.set || reminderDate != null);

  BulkTrackingAction copyWith({
    BulkTrackingTarget? tracking,
    BulkReminderMode? reminderMode,
    DateTime? Function()? reminderDate,
  }) => BulkTrackingAction(
    tracking: tracking ?? this.tracking,
    reminderMode: reminderMode ?? this.reminderMode,
    reminderDate: reminderDate == null ? this.reminderDate : reminderDate(),
  );

  Map<String, Object?> toJson({
    required Map<String, Object?> filter,
    List<int>? productIds,
  }) {
    final date = reminderDate;
    final reminder = reminderMode == BulkReminderMode.set && date != null
        ? formatApiDate(date)
        : null;
    return {
      'filter': filter,
      'tracking': tracking.apiValue,
      'reminder_mode': reminderMode.apiValue,
      'reminder_date': ?reminder,
      'product_ids': ?productIds,
    };
  }
}

enum BulkTrackingOutcome {
  change('change'),
  same('same'),
  blocked('blocked');

  const BulkTrackingOutcome(this.apiValue);
  final String apiValue;

  static BulkTrackingOutcome fromApi(Object? raw) {
    for (final outcome in values) {
      if (outcome.apiValue == raw) return outcome;
    }
    return BulkTrackingOutcome.blocked;
  }
}

enum BulkTrackingWarning {
  emptyShelf('empty_shelf'),
  undatedStock('undated_stock');

  const BulkTrackingWarning(this.apiValue);
  final String apiValue;

  static BulkTrackingWarning? fromApi(Object? raw) {
    for (final warning in values) {
      if (warning.apiValue == raw) return warning;
    }
    return null;
  }
}

class BulkTrackingRow {
  const BulkTrackingRow({
    required this.product,
    required this.name,
    required this.outcome,
    this.variants = 1,
    this.onHand = 0,
    this.currentMode = '',
    this.expiryRequired = false,
    this.message = '',
    this.warnings = const {},
  });

  factory BulkTrackingRow.fromJson(Map<String, dynamic> json) {
    return BulkTrackingRow(
      product: _int(json['product']),
      name: json['name']?.toString() ?? '',
      variants: _int(json['variants']),
      onHand: _decimal(json['on_hand']),
      currentMode: json['current_mode']?.toString() ?? '',
      expiryRequired: json['expiry_required'] == true,
      outcome: BulkTrackingOutcome.fromApi(json['outcome']),
      message: json['message']?.toString() ?? '',
      warnings: {
        for (final raw in (json['warnings'] as List?) ?? const [])
          ?BulkTrackingWarning.fromApi(raw),
      },
    );
  }

  final int product;
  final String name;
  final int variants;
  final double onHand;
  final String currentMode;
  final bool expiryRequired;
  final BulkTrackingOutcome outcome;

  /// The server's own (Arabic) reason, set when [outcome] is blocked.
  final String message;
  final Set<BulkTrackingWarning> warnings;

  bool get isEmptyShelf => warnings.contains(BulkTrackingWarning.emptyShelf);
  bool get isUndatedStock =>
      warnings.contains(BulkTrackingWarning.undatedStock);
}

class BulkTrackingSummary {
  const BulkTrackingSummary({
    this.matched = 0,
    this.change = 0,
    this.same = 0,
    this.blocked = 0,
    this.emptyShelf = 0,
    this.undatedStock = 0,
  });

  factory BulkTrackingSummary.fromJson(Map<String, dynamic> json) {
    return BulkTrackingSummary(
      matched: _int(json['matched']),
      change: _int(json['change']),
      same: _int(json['same']),
      blocked: _int(json['blocked']),
      emptyShelf: _int(json['empty_shelf']),
      undatedStock: _int(json['undated_stock']),
    );
  }

  final int matched;
  final int change;
  final int same;
  final int blocked;
  final int emptyShelf;
  final int undatedStock;
}

class BulkTrackingPreview {
  const BulkTrackingPreview({required this.summary, required this.rows});

  factory BulkTrackingPreview.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'];
    return BulkTrackingPreview(
      summary: summary is Map
          ? BulkTrackingSummary.fromJson(summary.cast())
          : const BulkTrackingSummary(),
      rows: [
        for (final raw in (json['results'] as List?) ?? const [])
          if (raw is Map) BulkTrackingRow.fromJson(raw.cast()),
      ],
    );
  }

  final BulkTrackingSummary summary;
  final List<BulkTrackingRow> rows;

  Iterable<BulkTrackingRow> byOutcome(BulkTrackingOutcome outcome) =>
      rows.where((row) => row.outcome == outcome);
}

class BulkTrackingFailure {
  const BulkTrackingFailure({required this.product, required this.message});

  final int product;
  final String message;
}

/// What one apply call (or, summed, a whole run) did.
class BulkTrackingApplyResult {
  const BulkTrackingApplyResult({
    this.done = 0,
    this.blocked = 0,
    this.failures = const [],
  });

  factory BulkTrackingApplyResult.fromJson(Map<String, dynamic> json) {
    return BulkTrackingApplyResult(
      done: _int(json['done']),
      blocked: _int(json['blocked']),
      failures: [
        for (final raw in (json['failures'] as List?) ?? const [])
          if (raw is Map)
            BulkTrackingFailure(
              product: _int(raw['product']),
              message: raw['message']?.toString() ?? '',
            ),
      ],
    );
  }

  final int done;
  final int blocked;
  final List<BulkTrackingFailure> failures;

  BulkTrackingApplyResult plus(BulkTrackingApplyResult other) =>
      BulkTrackingApplyResult(
        done: done + other.done,
        blocked: blocked + other.blocked,
        failures: [...failures, ...other.failures],
      );
}
