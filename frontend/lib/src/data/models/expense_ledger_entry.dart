/// Where a ledger row originates. Stable codes returned by the backend; the UI
/// maps them to Arabic labels + colored badges.
enum ExpenseLedgerSource {
  expense,
  registerPayout,
  purchase,
  payroll,
  commission,
  unknown;

  String get apiValue => switch (this) {
    ExpenseLedgerSource.expense => 'expense',
    ExpenseLedgerSource.registerPayout => 'register_payout',
    ExpenseLedgerSource.purchase => 'purchase',
    ExpenseLedgerSource.payroll => 'payroll',
    ExpenseLedgerSource.commission => 'commission',
    ExpenseLedgerSource.unknown => 'unknown',
  };

  static ExpenseLedgerSource fromApi(String? value) {
    return switch (value) {
      'expense' => ExpenseLedgerSource.expense,
      'register_payout' => ExpenseLedgerSource.registerPayout,
      'purchase' => ExpenseLedgerSource.purchase,
      'payroll' => ExpenseLedgerSource.payroll,
      'commission' => ExpenseLedgerSource.commission,
      _ => ExpenseLedgerSource.unknown,
    };
  }
}

/// One normalized money-out row in the unified ledger.
class ExpenseLedgerEntry {
  const ExpenseLedgerEntry({
    required this.source,
    required this.date,
    required this.amount,
    required this.description,
    required this.category,
    required this.paymentMethod,
    required this.reference,
    required this.relatedId,
  });

  final ExpenseLedgerSource source;
  final DateTime date;
  final double amount;
  final String description;
  final String? category;
  final String paymentMethod;
  final String reference;
  final int? relatedId;

  /// Only ad-hoc expense rows can be edited/deleted from the ledger.
  bool get isEditable => source == ExpenseLedgerSource.expense;

  factory ExpenseLedgerEntry.fromJson(Map<String, Object?> json) {
    return ExpenseLedgerEntry(
      source: ExpenseLedgerSource.fromApi(json['source']?.toString()),
      date: DateTime.tryParse(json['date']?.toString() ?? '') ?? DateTime.now(),
      amount: double.tryParse(json['amount']?.toString() ?? '') ?? 0,
      description: json['description']?.toString() ?? '',
      category: json['category']?.toString(),
      paymentMethod: json['payment_method']?.toString() ?? '',
      reference: json['reference']?.toString() ?? '',
      relatedId: (json['related_id'] as num?)?.toInt(),
    );
  }
}

/// The full ledger response: rows, per-source totals, and a grand total.
class ExpenseLedger {
  const ExpenseLedger({
    required this.start,
    required this.end,
    required this.entries,
    required this.totalsBySource,
    required this.total,
    required this.truncated,
    required this.totalCount,
  });

  final DateTime start;
  final DateTime end;
  final List<ExpenseLedgerEntry> entries;
  final Map<ExpenseLedgerSource, double> totalsBySource;
  final double total;
  final bool truncated;
  final int totalCount;

  static ExpenseLedger empty(DateTime start, DateTime end) {
    return ExpenseLedger(
      start: start,
      end: end,
      entries: const [],
      totalsBySource: const {},
      total: 0,
      truncated: false,
      totalCount: 0,
    );
  }

  double totalFor(ExpenseLedgerSource source) => totalsBySource[source] ?? 0;

  factory ExpenseLedger.fromJson(Map<String, Object?> json) {
    final entries = ((json['rows'] as List<Object?>?) ?? const [])
        .cast<Map<String, Object?>>()
        .map(ExpenseLedgerEntry.fromJson)
        .toList(growable: false);

    final totalsJson = (json['totals'] as Map<String, Object?>?) ?? const {};
    final totals = <ExpenseLedgerSource, double>{};
    for (final entry in totalsJson.entries) {
      totals[ExpenseLedgerSource.fromApi(entry.key)] =
          double.tryParse(entry.value?.toString() ?? '') ?? 0;
    }

    final summary = (json['summary'] as Map<String, Object?>?) ?? const {};
    return ExpenseLedger(
      start:
          DateTime.tryParse(json['start']?.toString() ?? '') ?? DateTime.now(),
      end: DateTime.tryParse(json['end']?.toString() ?? '') ?? DateTime.now(),
      entries: entries,
      totalsBySource: totals,
      total: double.tryParse(summary['total']?.toString() ?? '') ?? 0,
      truncated: summary['truncated'] == true,
      totalCount: (summary['total_count'] as num?)?.toInt() ?? entries.length,
    );
  }
}
