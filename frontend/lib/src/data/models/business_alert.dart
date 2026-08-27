import 'analytics_event.dart';

enum BusinessAlertSeverity {
  critical,
  warning,
  info;

  int get priority => switch (this) {
    BusinessAlertSeverity.critical => 0,
    BusinessAlertSeverity.warning => 1,
    BusinessAlertSeverity.info => 2,
  };
}

enum BusinessAlertCategory {
  inventory,
  purchasing,
  printing,
  sales,
  fraud,
  discounts,
  operations,
}

enum BusinessAlertType {
  outOfStock,
  lowStock,
  stockPositionUntrusted,
  expiringStock,
  overduePurchases,
  printFailures,
  stalePrintAgents,
  suspectedCashierActivity,
  registerVariance,
  lowProfitMargin,
  expiringDiscounts,
  payrollReady,
  operationsError,
  unknown,
}

class BusinessAlert {
  const BusinessAlert({
    required this.id,
    required this.code,
    required this.type,
    required this.category,
    required this.severity,
    required this.sortScore,
    required this.isHidden,
    this.hiddenReason = '',
    this.count = 0,
    this.quantity = 0,
    this.threshold = 0,
    this.days = 0,
    this.amount = 0,
    this.percent = 0,
    this.riskScore = 0,
    this.primaryLabel = '',
    this.secondaryLabel = '',
    this.detailLabel = '',
    this.firstSeenAt,
    this.lastSeenAt,
    this.occurredAt,
    this.acknowledgedAt,
    this.snoozedUntil,
    this.payload = const {},
  });

  final String id;
  final String code;
  final BusinessAlertType type;
  final BusinessAlertCategory category;
  final BusinessAlertSeverity severity;
  final int sortScore;
  final bool isHidden;
  final String hiddenReason;
  final int count;
  final int quantity;
  final int threshold;
  final int days;
  final double amount;
  final double percent;
  final int riskScore;
  final String primaryLabel;
  final String secondaryLabel;
  final String detailLabel;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;
  final DateTime? occurredAt;
  final DateTime? acknowledgedAt;
  final DateTime? snoozedUntil;
  final Map<String, Object?> payload;

  bool get hasInvestigationQuery {
    return _mapFromJson(payload['investigation_query']).isNotEmpty;
  }

  String get investigationReason {
    final headline = payload['headline']?.toString() ?? '';
    if (headline.trim().isNotEmpty) {
      return headline;
    }
    return payload['rule_title']?.toString() ?? '';
  }

  AnalyticsEventQuery? investigationActivityQuery() {
    final query = _mapFromJson(payload['investigation_query']);
    if (query.isEmpty) {
      return null;
    }
    final userId = _intFromJson(query['received_by']);
    final userLabel = payload['user_label']?.toString() ?? primaryLabel;
    return AnalyticsEventQuery(
      activityScope: _activityScopeFromJson(query['activity_scope']),
      dateRange: AnalyticsEventDateRange.custom,
      occurredAfter: _nullableDateTimeFromJson(query['occurred_at_after']),
      occurredBefore: _nullableDateTimeFromJson(query['occurred_at_before']),
      userIds: userId <= 0 ? const [] : [userId],
      userLabels: userId <= 0 || userLabel.trim().isEmpty
          ? const []
          : [userLabel],
      registerSessionId: query['session_id']?.toString() ?? '',
      entityType: query['entity_type']?.toString() ?? '',
      entityId: query['entity_id']?.toString() ?? '',
      minRiskScore: _nullableIntFromJson(query['risk_score_min']),
      ordering: _orderingFromJson(query['ordering']),
    );
  }

  factory BusinessAlert.fromJson(Map<String, Object?> json) {
    final code = json['code']?.toString() ?? '';
    final payload = _mapFromJson(json['payload']);
    final type = _typeFromCode(code);
    return BusinessAlert(
      id: json['id']?.toString() ?? '',
      code: code,
      type: type,
      category: _categoryFromJson(json['category']),
      severity: _severityFromJson(json['severity']),
      sortScore: _sortScore(type),
      isHidden: json['is_hidden'] == true,
      hiddenReason: json['hidden_reason']?.toString() ?? '',
      count: _intFromJson(payload['count'], fallback: 1),
      quantity: _quantityFromPayload(type, payload),
      threshold: _intFromJson(payload['threshold']),
      days: _intFromJson(payload['days']),
      amount: _doubleFromJson(payload['amount']),
      percent: _doubleFromJson(payload['percent']),
      riskScore: _intFromJson(payload['risk_score']),
      primaryLabel: _primaryLabel(type, payload),
      secondaryLabel: _secondaryLabel(type, payload),
      detailLabel: _detailLabel(type, payload),
      firstSeenAt: _dateTimeFromJson(json['first_seen_at']),
      lastSeenAt: _dateTimeFromJson(json['last_seen_at']),
      occurredAt: _occurredAt(type, payload),
      acknowledgedAt: _dateTimeFromJson(json['acknowledged_at']),
      snoozedUntil: _dateTimeFromJson(json['snoozed_until']),
      payload: payload,
    );
  }

  BusinessAlert copyWith({bool? isHidden, String? hiddenReason}) {
    return BusinessAlert(
      id: id,
      code: code,
      type: type,
      category: category,
      severity: severity,
      sortScore: sortScore,
      isHidden: isHidden ?? this.isHidden,
      hiddenReason: hiddenReason ?? this.hiddenReason,
      count: count,
      quantity: quantity,
      threshold: threshold,
      days: days,
      amount: amount,
      percent: percent,
      riskScore: riskScore,
      primaryLabel: primaryLabel,
      secondaryLabel: secondaryLabel,
      detailLabel: detailLabel,
      firstSeenAt: firstSeenAt,
      lastSeenAt: lastSeenAt,
      occurredAt: occurredAt,
      acknowledgedAt: acknowledgedAt,
      snoozedUntil: snoozedUntil,
      payload: payload,
    );
  }
}

class BusinessAlertDigest {
  const BusinessAlertDigest({required this.alerts, this.generatedAt});

  final List<BusinessAlert> alerts;
  final DateTime? generatedAt;
}

BusinessAlertType _typeFromCode(String code) {
  return switch (code) {
    'inventory.out_of_stock' => BusinessAlertType.outOfStock,
    'inventory.low_stock' => BusinessAlertType.lowStock,
    'inventory.position_untrusted' => BusinessAlertType.stockPositionUntrusted,
    'inventory.expiring_batch' => BusinessAlertType.expiringStock,
    'purchasing.overdue_order' => BusinessAlertType.overduePurchases,
    'printing.failed_job' => BusinessAlertType.printFailures,
    'printing.stale_agent' => BusinessAlertType.stalePrintAgents,
    'fraud.suspected_cashier_activity' =>
      BusinessAlertType.suspectedCashierActivity,
    'sales.register_variance' => BusinessAlertType.registerVariance,
    'sales.negative_margin' => BusinessAlertType.lowProfitMargin,
    'discounts.expiring_rule' => BusinessAlertType.expiringDiscounts,
    'employees.payroll_ready' => BusinessAlertType.payrollReady,
    'operations.backend_error' => BusinessAlertType.operationsError,
    _ => BusinessAlertType.unknown,
  };
}

BusinessAlertCategory _categoryFromJson(Object? value) {
  return switch (value?.toString()) {
    'inventory' => BusinessAlertCategory.inventory,
    'purchasing' => BusinessAlertCategory.purchasing,
    'printing' => BusinessAlertCategory.printing,
    'sales' => BusinessAlertCategory.sales,
    'fraud' => BusinessAlertCategory.fraud,
    'discounts' => BusinessAlertCategory.discounts,
    'operations' => BusinessAlertCategory.operations,
    _ => BusinessAlertCategory.operations,
  };
}

BusinessAlertSeverity _severityFromJson(Object? value) {
  return switch (value?.toString()) {
    'critical' => BusinessAlertSeverity.critical,
    'warning' => BusinessAlertSeverity.warning,
    _ => BusinessAlertSeverity.info,
  };
}

int _sortScore(BusinessAlertType type) {
  return switch (type) {
    BusinessAlertType.stockPositionUntrusted => 9,
    BusinessAlertType.outOfStock => 10,
    BusinessAlertType.printFailures => 15,
    BusinessAlertType.stalePrintAgents => 18,
    BusinessAlertType.suspectedCashierActivity => 19,
    BusinessAlertType.overduePurchases => 20,
    BusinessAlertType.expiringStock => 22,
    BusinessAlertType.registerVariance => 25,
    BusinessAlertType.lowProfitMargin => 28,
    BusinessAlertType.lowStock => 30,
    BusinessAlertType.payrollReady => 32,
    BusinessAlertType.operationsError => 35,
    BusinessAlertType.expiringDiscounts => 60,
    BusinessAlertType.unknown => 100,
  };
}

int _quantityFromPayload(BusinessAlertType type, Map<String, Object?> payload) {
  return switch (type) {
    BusinessAlertType.stalePrintAgents => _intFromJson(payload['queued_count']),
    BusinessAlertType.suspectedCashierActivity => _intFromJson(
      payload['risk_score'],
    ),
    _ => _intFromJson(payload['quantity']),
  };
}

String _primaryLabel(BusinessAlertType type, Map<String, Object?> payload) {
  return switch (type) {
    BusinessAlertType.outOfStock ||
    BusinessAlertType.lowStock ||
    BusinessAlertType.expiringStock =>
      payload['product_name']?.toString() ?? '',
    BusinessAlertType.overduePurchases =>
      payload['order_number']?.toString() ?? '',
    BusinessAlertType.printFailures =>
      payload['receipt_number']?.toString() ?? '',
    BusinessAlertType.stalePrintAgents =>
      payload['agent_name']?.toString() ?? '',
    BusinessAlertType.suspectedCashierActivity =>
      payload['user_label']?.toString() ?? '',
    BusinessAlertType.registerVariance =>
      payload['session_number']?.toString() ?? '',
    BusinessAlertType.expiringDiscounts =>
      payload['rule_name']?.toString() ?? '',
    BusinessAlertType.payrollReady => payload['run_number']?.toString() ?? '',
    BusinessAlertType.operationsError => payload['name']?.toString() ?? '',
    BusinessAlertType.stockPositionUntrusted ||
    BusinessAlertType.lowProfitMargin ||
    BusinessAlertType.unknown => '',
  };
}

String _secondaryLabel(BusinessAlertType type, Map<String, Object?> payload) {
  return switch (type) {
    BusinessAlertType.outOfStock ||
    BusinessAlertType.lowStock ||
    BusinessAlertType.expiringStock => payload['sku']?.toString() ?? '',
    BusinessAlertType.overduePurchases =>
      payload['supplier_name']?.toString() ?? '',
    BusinessAlertType.printFailures => payload['message']?.toString() ?? '',
    BusinessAlertType.expiringDiscounts => payload['channel']?.toString() ?? '',
    BusinessAlertType.payrollReady => payload['period_start']?.toString() ?? '',
    BusinessAlertType.suspectedCashierActivity =>
      payload['rule_title']?.toString() ?? '',
    BusinessAlertType.operationsError => payload['source']?.toString() ?? '',
    _ => '',
  };
}

String _detailLabel(BusinessAlertType type, Map<String, Object?> payload) {
  return switch (type) {
    BusinessAlertType.expiringStock => _stockBatchDetail(payload),
    BusinessAlertType.suspectedCashierActivity =>
      payload['headline']?.toString() ?? '',
    BusinessAlertType.payrollReady => payload['period_end']?.toString() ?? '',
    BusinessAlertType.operationsError => payload['message']?.toString() ?? '',
    _ => '',
  };
}

DateTime? _occurredAt(BusinessAlertType type, Map<String, Object?> payload) {
  return switch (type) {
    BusinessAlertType.overduePurchases => _dateTimeFromJson(
      payload['due_date'],
    ),
    BusinessAlertType.expiringStock => _dateTimeFromJson(
      payload['expiry_date'],
    ),
    BusinessAlertType.printFailures => _dateTimeFromJson(payload['failed_at']),
    BusinessAlertType.expiringDiscounts => _dateTimeFromJson(
      payload['ends_at'],
    ),
    BusinessAlertType.suspectedCashierActivity => _dateTimeFromJson(
      payload['window_end'],
    ),
    BusinessAlertType.operationsError => _dateTimeFromJson(
      payload['occurred_at'],
    ),
    _ => null,
  };
}

String _stockBatchDetail(Map<String, Object?> payload) {
  final parts = [
    payload['supplier_name']?.toString().trim() ?? '',
    payload['order_number']?.toString().trim() ?? '',
  ].where((value) => value.isNotEmpty);
  return parts.join(' • ');
}

Map<String, Object?> _mapFromJson(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

DateTime? _dateTimeFromJson(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '');
}

DateTime? _nullableDateTimeFromJson(Object? value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  return null;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null || value.toString().trim().isEmpty) {
    return null;
  }
  final parsed = _intFromJson(value);
  return parsed;
}

AnalyticsEventActivityScope _activityScopeFromJson(Object? value) {
  return switch (value?.toString()) {
    'all' => AnalyticsEventActivityScope.all,
    'technical' => AnalyticsEventActivityScope.technical,
    _ => AnalyticsEventActivityScope.reviewable,
  };
}

AnalyticsEventOrdering _orderingFromJson(Object? value) {
  return switch (value?.toString()) {
    'occurred_at' => AnalyticsEventOrdering.oldest,
    '-risk_score' => AnalyticsEventOrdering.highestRisk,
    '-created_at' => AnalyticsEventOrdering.newestReceived,
    _ => AnalyticsEventOrdering.newest,
  };
}

int _intFromJson(Object? value, {int fallback = 0}) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _doubleFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
