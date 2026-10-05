/// كشف حساب صاحب الأمانة — one consignor's whole page, across every agreement
/// they signed.
///
/// Every money figure arrives computed by the server: a payable the client
/// added up from the rows on screen is a payable that disagrees with the ledger
/// the moment the list is paged.
library;

/// Where one article stands with its owner, in the order the page lists them.
class ConsignorLineState {
  const ConsignorLineState._();

  /// Sold; the money waits for them.
  static const awaiting = 'awaiting';

  /// On the shop's shelf, still theirs.
  static const held = 'held';

  /// Sold and settled.
  static const paid = 'paid';

  /// Handed back unsold.
  static const returned = 'returned';

  /// Damaged or written off — its custody incident says the rest.
  static const lost = 'lost';

  static const all = [awaiting, held, paid, returned, lost];
}

/// The filters the statement screen offers. `closed` is the two rare states
/// together: a chip each for "returned" and "lost" would be two chips nobody
/// presses.
enum ConsignorLineFilter {
  all(<String>[]),
  awaiting([ConsignorLineState.awaiting]),
  held([ConsignorLineState.held]),
  paid([ConsignorLineState.paid]),
  closed([ConsignorLineState.returned, ConsignorLineState.lost]);

  const ConsignorLineFilter(this.states);

  final List<String> states;
}

class ConsignorStatement {
  const ConsignorStatement({
    required this.consignorId,
    this.consignorName = '',
    this.consignorPhone = '',
    this.doNotContact = false,
    this.figures = const ConsignorStatementFigures(),
    this.reminders = const ConsignorReminderSummary(),
  });

  final int consignorId;
  final String consignorName;
  final String consignorPhone;
  final bool doNotContact;
  final ConsignorStatementFigures figures;
  final ConsignorReminderSummary reminders;

  factory ConsignorStatement.fromJson(Map<String, Object?> json) {
    final consignor = _map(json['consignor']);
    return ConsignorStatement(
      consignorId: _int(consignor['id']),
      consignorName: consignor['full_name']?.toString() ?? '',
      consignorPhone: consignor['phone']?.toString() ?? '',
      doNotContact: consignor['do_not_contact'] == true,
      figures: ConsignorStatementFigures.fromJson(_map(json['figures'])),
      reminders: ConsignorReminderSummary.fromJson(_map(json['reminders'])),
    );
  }
}

/// The headline: what is owed now, and what the chosen period did.
class ConsignorStatementFigures {
  const ConsignorStatementFigures({
    this.payable = 0,
    this.receivable = 0,
    this.claimsOpen = 0,
    this.claimsUnassessed = 0,
    this.totalCount = 0,
    this.heldCount = 0,
    this.heldDeclaredValue = 0,
    this.awaitingCount = 0,
    this.oldestAwaitingAt,
    this.paidCount = 0,
    this.returnedCount = 0,
    this.lostCount = 0,
    this.periodSoldCount = 0,
    this.periodSoldValue = 0,
    this.periodPaidTotal = 0,
    this.periodPayoutCount = 0,
    this.agreementCount = 0,
    this.shopCommission,
  });

  /// What the shop owes this consignor right now, net of any advance.
  final double payable;

  /// What this consignor owes the shop: paid out for an article that came
  /// back. Shown beside the payable, never netted into it.
  final double receivable;
  final double claimsOpen;
  final int claimsUnassessed;
  final int totalCount;
  final int heldCount;
  final double heldDeclaredValue;
  final int awaitingCount;
  final DateTime? oldestAwaitingAt;
  final int paidCount;
  final int returnedCount;
  final int lostCount;
  final int periodSoldCount;
  final double periodSoldValue;
  final double periodPaidTotal;
  final int periodPayoutCount;
  final int agreementCount;

  /// The shop's earning on this consignor's goods. Null for anybody outside
  /// the reporting roles — the server leaves it out rather than zeroing it.
  final double? shopCommission;

  /// Whether this customer has ever left anything with the shop.
  bool get hasHistory => totalCount > 0 || agreementCount > 0;

  int? get oldestAwaitingDays {
    final oldest = oldestAwaitingAt;
    if (oldest == null) {
      return null;
    }
    return DateTime.now().difference(oldest).inDays;
  }

  factory ConsignorStatementFigures.fromJson(Map<String, Object?> json) {
    return ConsignorStatementFigures(
      payable: _double(json['payable']),
      receivable: _double(json['receivable']),
      claimsOpen: _double(json['claims_open']),
      claimsUnassessed: _int(json['claims_unassessed']),
      totalCount: _int(json['total_count']),
      heldCount: _int(json['held_count']),
      heldDeclaredValue: _double(json['held_declared_value']),
      awaitingCount: _int(json['awaiting_count']),
      oldestAwaitingAt: _date(json['oldest_awaiting_at']),
      paidCount: _int(json['paid_count']),
      returnedCount: _int(json['returned_count']),
      lostCount: _int(json['lost_count']),
      periodSoldCount: _int(json['period_sold_count']),
      periodSoldValue: _double(json['period_sold_value']),
      periodPaidTotal: _double(json['period_paid_total']),
      periodPayoutCount: _int(json['period_payout_count']),
      agreementCount: _int(json['agreement_count']),
      shopCommission: json.containsKey('shop_commission')
          ? _double(json['shop_commission'])
          : null,
    );
  }
}

/// Whether the shop reminds consignors of uncollected money, and the last time
/// this one was reminded.
class ConsignorReminderSummary {
  const ConsignorReminderSummary({
    this.enabled = false,
    this.everyDays = 0,
    this.maxRounds = 3,
    this.lastAt,
    this.lastStatus,
  });

  final bool enabled;
  final int everyDays;
  final int maxRounds;
  final DateTime? lastAt;
  final String? lastStatus;

  factory ConsignorReminderSummary.fromJson(Map<String, Object?> json) {
    return ConsignorReminderSummary(
      enabled: json['enabled'] == true,
      everyDays: _int(json['every_days']),
      maxRounds: _int(json['max_rounds'], fallback: 3),
      lastAt: _date(json['last_at']),
      lastStatus: json['last_status']?.toString(),
    );
  }
}

/// The latest reminder about one article's current sale.
class ConsignorLineReminder {
  const ConsignorLineReminder({
    required this.sentAt,
    required this.round,
    this.status,
  });

  final DateTime sentAt;
  final int round;
  final String? status;

  /// A message that never reached the consignor — the line says so rather than
  /// claiming they were told.
  bool get failed =>
      status == 'failed' || status == 'expired' || status == 'cancelled';

  static ConsignorLineReminder? fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final sentAt = _date(json['sent_at']);
    if (sentAt == null) {
      return null;
    }
    return ConsignorLineReminder(
      sentAt: sentAt,
      round: _int(json['round']),
      status: json['status']?.toString(),
    );
  }
}

/// One article on the statement, wherever it stands.
class ConsignorStatementLine {
  const ConsignorStatementLine({
    required this.unitId,
    required this.code,
    required this.state,
    this.productName = '',
    this.agreementId,
    this.agreementNumber = '',
    this.activityAt,
    this.acquiredAt,
    this.declaredValue,
    this.listPrice,
    this.soldAt,
    this.soldPrice,
    this.payoutDue = 0,
    this.payoutIsEstimate = false,
    this.advance = 0,
    this.netDue = 0,
    this.paidAt,
    this.payoutNumber = '',
    this.invoiceNumber = '',
    this.soldOnCredit = false,
    this.daysWaiting,
    this.lastReminder,
  });

  final int unitId;
  final String code;
  final String state;
  final String productName;
  final int? agreementId;
  final String agreementNumber;

  /// The date that places the article in time: sold, paid, taken in.
  final DateTime? activityAt;
  final DateTime? acquiredAt;
  final double? declaredValue;
  final double? listPrice;
  final DateTime? soldAt;
  final double? soldPrice;

  /// What the article earned (or, on the shelf, would earn at its asking
  /// price — [payoutIsEstimate]).
  final double payoutDue;
  final bool payoutIsEstimate;
  final double advance;

  /// What the counter hands over for it now.
  final double netDue;
  final DateTime? paidAt;
  final String payoutNumber;
  final String invoiceNumber;
  final bool soldOnCredit;
  final int? daysWaiting;
  final ConsignorLineReminder? lastReminder;

  bool get isAwaiting => state == ConsignorLineState.awaiting;

  factory ConsignorStatementLine.fromJson(Map<String, Object?> json) {
    return ConsignorStatementLine(
      unitId: _int(json['id']),
      code: json['code']?.toString() ?? '',
      state: json['state']?.toString() ?? ConsignorLineState.held,
      productName: json['product_name']?.toString() ?? '',
      agreementId: _intOrNull(json['agreement']),
      agreementNumber: json['agreement_number']?.toString() ?? '',
      activityAt: _date(json['activity_at']),
      acquiredAt: _date(json['acquired_at']),
      declaredValue: _doubleOrNull(json['declared_value']),
      listPrice: _doubleOrNull(json['list_price']),
      soldAt: _date(json['sold_at']),
      soldPrice: _doubleOrNull(json['sold_price']),
      payoutDue: _double(json['payout_due']),
      payoutIsEstimate: json['payout_is_estimate'] == true,
      advance: _double(json['advance']),
      netDue: _double(json['net_due']),
      paidAt: _date(json['paid_at']),
      payoutNumber: json['payout_number']?.toString() ?? '',
      invoiceNumber: json['invoice_number']?.toString() ?? '',
      soldOnCredit: json['sold_on_credit'] == true,
      daysWaiting: _intOrNull(json['days_waiting']),
      lastReminder: ConsignorLineReminder.fromJson(json['last_reminder']),
    );
  }
}

/// One page of the statement: the headline (on every page, so a reload never
/// shows lines under a stale total) and that page's lines.
class ConsignorStatementPage {
  const ConsignorStatementPage({
    required this.statement,
    this.lines = const [],
    this.count = 0,
    this.hasNext = false,
  });

  final ConsignorStatement statement;
  final List<ConsignorStatementLine> lines;
  final int count;
  final bool hasNext;

  factory ConsignorStatementPage.fromJson(Map<String, Object?> json) {
    final results = json['results'];
    final lines = results is List<Object?>
        ? results
              .whereType<Map<String, Object?>>()
              .map(ConsignorStatementLine.fromJson)
              .toList(growable: false)
        : const <ConsignorStatementLine>[];
    return ConsignorStatementPage(
      statement: ConsignorStatement.fromJson(json),
      lines: lines,
      count: _intOrNull(json['count']) ?? lines.length,
      hasNext: json['next'] != null,
    );
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

int _int(Object? value, {int fallback = 0}) => _intOrNull(value) ?? fallback;

int? _intOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

double _double(Object? value) => _doubleOrNull(value) ?? 0;

double? _doubleOrNull(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '');
}

DateTime? _date(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) {
    return null;
  }
  return DateTime.tryParse(text)?.toLocal();
}
