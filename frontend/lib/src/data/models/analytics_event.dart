import 'dart:math';

import 'query.dart';

enum AnalyticsEventType {
  usage,
  error,
  performance,
  security,
  fraudSignal,
  audit,
}

enum AnalyticsEventSeverity { debug, info, warning, error, critical }

enum AnalyticsEventSource { frontend, backend, printAgent, integration }

enum AnalyticsEventName {
  appStarted,
  appFlutterError,
  appPlatformError,
  authSessionStarted,
  authLoginSucceeded,
  authLoginFailed,
  authLogout,
  frontendFrameTiming,
  frontendHttpRequest,
  frontendOperation,
  frontendScreenViewed,
  frontendInteraction,
  appLifecycleChanged,
  telemetryQueueHealth,
  analyticsExportStarted,
  analyticsExportCompleted,
  analyticsExportFailed,
  analyticsExportDownloaded,
  analyticsExportDownloadFailed,
  reportGenerated,
  reportGenerationFailed,
  reportPreviewed,
  reportPrinted,
  reportShared,
  posCheckoutStarted,
  posCheckoutCompleted,
  posCheckoutFailed,
  posCheckoutStockRejected,
}

class AnalyticsEventDraft {
  AnalyticsEventDraft({
    required this.eventType,
    required this.name,
    String? clientEventId,
    this.severity = AnalyticsEventSeverity.info,
    this.source = AnalyticsEventSource.frontend,
    DateTime? occurredAt,
    this.sessionId,
    this.deviceId,
    this.installationId,
    this.appVersion,
    this.platform,
    this.traceId,
    this.entityType,
    this.entityId,
    this.riskScore,
    this.attributes = const {},
    this.metrics = const {},
  }) : clientEventId = clientEventId ?? generateAnalyticsEventId(),
       occurredAt = occurredAt ?? DateTime.now().toUtc();

  factory AnalyticsEventDraft.usage(
    AnalyticsEventName name, {
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.info,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    String? entityType,
    String? entityId,
    DateTime? occurredAt,
  }) {
    return AnalyticsEventDraft(
      eventType: AnalyticsEventType.usage,
      name: analyticsEventNameToJson(name),
      severity: severity,
      occurredAt: occurredAt,
      entityType: entityType,
      entityId: entityId,
      attributes: attributes,
      metrics: metrics,
    );
  }

  factory AnalyticsEventDraft.error(
    AnalyticsEventName name, {
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.error,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    String? entityType,
    String? entityId,
    DateTime? occurredAt,
  }) {
    return AnalyticsEventDraft(
      eventType: AnalyticsEventType.error,
      name: analyticsEventNameToJson(name),
      severity: severity,
      occurredAt: occurredAt,
      entityType: entityType,
      entityId: entityId,
      attributes: attributes,
      metrics: metrics,
    );
  }

  factory AnalyticsEventDraft.performance({
    required String name,
    required Duration duration,
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.info,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    String? entityType,
    String? entityId,
    DateTime? occurredAt,
  }) {
    return AnalyticsEventDraft(
      eventType: AnalyticsEventType.performance,
      name: name,
      severity: severity,
      occurredAt: occurredAt,
      entityType: entityType,
      entityId: entityId,
      attributes: attributes,
      metrics: {'duration_ms': duration.inMicroseconds / 1000, ...metrics},
    );
  }

  factory AnalyticsEventDraft.fraudSignal({
    required String name,
    required int riskScore,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    String? entityType,
    String? entityId,
    DateTime? occurredAt,
  }) {
    return AnalyticsEventDraft(
      eventType: AnalyticsEventType.fraudSignal,
      name: name,
      severity: AnalyticsEventSeverity.warning,
      occurredAt: occurredAt,
      riskScore: riskScore.clamp(0, 100).toInt(),
      entityType: entityType,
      entityId: entityId,
      attributes: attributes,
      metrics: metrics,
    );
  }

  factory AnalyticsEventDraft.audit({
    required String name,
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.info,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    String? sessionId,
    String? entityType,
    String? entityId,
    DateTime? occurredAt,
  }) {
    return AnalyticsEventDraft(
      eventType: AnalyticsEventType.audit,
      name: name,
      severity: severity,
      occurredAt: occurredAt,
      sessionId: sessionId,
      entityType: entityType,
      entityId: entityId,
      attributes: attributes,
      metrics: metrics,
    );
  }

  factory AnalyticsEventDraft.fromJson(Map<String, Object?> json) {
    return AnalyticsEventDraft(
      clientEventId: json['client_event_id']?.toString(),
      eventType: analyticsEventTypeFromJson(json['event_type']?.toString()),
      name:
          json['name']?.toString() ??
          analyticsEventNameToJson(AnalyticsEventName.appStarted),
      severity: analyticsEventSeverityFromJson(json['severity']?.toString()),
      source: analyticsEventSourceFromJson(json['source']?.toString()),
      occurredAt: _dateTimeFromJson(json['occurred_at']),
      sessionId: _stringOrNull(json['session_id']),
      deviceId: _stringOrNull(json['device_id']),
      installationId: _stringOrNull(json['installation_id']),
      appVersion: _stringOrNull(json['app_version']),
      platform: _stringOrNull(json['platform']),
      traceId: _stringOrNull(json['trace_id']),
      entityType: _stringOrNull(json['entity_type']),
      entityId: _stringOrNull(json['entity_id']),
      riskScore: (json['risk_score'] as num?)?.toInt(),
      attributes: _objectMapFromJson(json['attributes']),
      metrics: _numericMapFromJson(json['metrics']),
    );
  }

  final String clientEventId;
  final AnalyticsEventType eventType;
  final String name;
  final AnalyticsEventSeverity severity;
  final AnalyticsEventSource source;
  final DateTime occurredAt;
  final String? sessionId;
  final String? deviceId;
  final String? installationId;
  final String? appVersion;
  final String? platform;
  final String? traceId;
  final String? entityType;
  final String? entityId;
  final int? riskScore;
  final Map<String, Object?> attributes;
  final Map<String, num> metrics;

  AnalyticsEventDraft copyWith({
    String? sessionId,
    String? deviceId,
    String? installationId,
    String? appVersion,
    String? platform,
    String? traceId,
    String? entityType,
    String? entityId,
    int? riskScore,
    Map<String, Object?>? attributes,
    Map<String, num>? metrics,
  }) {
    return AnalyticsEventDraft(
      clientEventId: clientEventId,
      eventType: eventType,
      name: name,
      severity: severity,
      source: source,
      occurredAt: occurredAt,
      sessionId: sessionId ?? this.sessionId,
      deviceId: deviceId ?? this.deviceId,
      installationId: installationId ?? this.installationId,
      appVersion: appVersion ?? this.appVersion,
      platform: platform ?? this.platform,
      traceId: traceId ?? this.traceId,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      riskScore: riskScore ?? this.riskScore,
      attributes: attributes ?? this.attributes,
      metrics: metrics ?? this.metrics,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'client_event_id': clientEventId,
      'event_type': analyticsEventTypeToJson(eventType),
      'name': name,
      'severity': analyticsEventSeverityToJson(severity),
      'source': analyticsEventSourceToJson(source),
      'occurred_at': occurredAt.toUtc().toIso8601String(),
      if (sessionId != null && sessionId!.isNotEmpty) 'session_id': sessionId,
      if (deviceId != null && deviceId!.isNotEmpty) 'device_id': deviceId,
      if (installationId != null && installationId!.isNotEmpty)
        'installation_id': installationId,
      if (appVersion != null && appVersion!.isNotEmpty)
        'app_version': appVersion,
      if (platform != null && platform!.isNotEmpty) 'platform': platform,
      if (traceId != null && traceId!.isNotEmpty) 'trace_id': traceId,
      if (entityType != null && entityType!.isNotEmpty)
        'entity_type': entityType,
      if (entityId != null && entityId!.isNotEmpty) 'entity_id': entityId,
      if (riskScore != null) 'risk_score': riskScore,
      'attributes': _encodableAttributes(attributes),
      'metrics': _encodableMetrics(metrics),
    };
  }
}

/// Replaces anything `jsonEncode` cannot represent.
///
/// A double can be `Infinity` or `NaN` — a division by zero away — and
/// `jsonEncode` throws on both. That throw does not stay local: the queue is
/// encoded as a whole, so one poisoned metric makes *every* later write fail,
/// each failure is itself recorded as an error, and recording it triggers
/// another write. In the field that ran at seventeen errors a second for two
/// minutes and produced 1,999 of the dump's 2,167 platform errors — 92% of
/// them — burying every other signal.
///
/// Telemetry is not worth a loop, so a value that cannot be encoded is replaced
/// by a string naming what it was. The reading stays legible and the queue
/// always encodes.
Map<String, num> _encodableMetrics(Map<String, num> metrics) {
  if (metrics.values.every(_isEncodableNumber)) {
    return metrics;
  }
  return {
    for (final entry in metrics.entries)
      if (_isEncodableNumber(entry.value)) entry.key: entry.value,
  };
}

Map<String, Object?> _encodableAttributes(Map<String, Object?> attributes) {
  if (attributes.values.every(
    (value) => value is! num || _isEncodableNumber(value),
  )) {
    return attributes;
  }
  return {
    for (final entry in attributes.entries)
      entry.key: (entry.value is num && !_isEncodableNumber(entry.value as num))
          ? '${entry.value}'
          : entry.value,
  };
}

bool _isEncodableNumber(num value) => value is! double || value.isFinite;


class AnalyticsIngestResult {
  const AnalyticsIngestResult({
    required this.accepted,
    required this.duplicates,
    this.eventIds = const [],
    this.duplicateEventIds = const [],
  });

  factory AnalyticsIngestResult.fromJson(Map<String, Object?> json) {
    return AnalyticsIngestResult(
      accepted: (json['accepted'] as num?)?.toInt() ?? 0,
      duplicates: (json['duplicates'] as num?)?.toInt() ?? 0,
      eventIds: _stringListFromJson(json['event_ids']),
      duplicateEventIds: _stringListFromJson(json['duplicate_event_ids']),
    );
  }

  final int accepted;
  final int duplicates;
  final List<String> eventIds;
  final List<String> duplicateEventIds;
}

enum AnalyticsEventTypeFilter implements QueryFilterSet {
  all(null),
  audit(QueryFilter(parameter: 'event_type', value: 'audit')),
  fraudSignal(QueryFilter(parameter: 'event_type', value: 'fraud_signal')),
  security(QueryFilter(parameter: 'event_type', value: 'security')),
  error(QueryFilter(parameter: 'event_type', value: 'error')),
  performance(QueryFilter(parameter: 'event_type', value: 'performance')),
  usage(QueryFilter(parameter: 'event_type', value: 'usage'));

  const AnalyticsEventTypeFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum AnalyticsEventSeverityFilter implements QueryFilterSet {
  all(null),
  warning(QueryFilter(parameter: 'severity', value: 'warning')),
  error(QueryFilter(parameter: 'severity', value: 'error')),
  critical(QueryFilter(parameter: 'severity', value: 'critical')),
  info(QueryFilter(parameter: 'severity', value: 'info')),
  debug(QueryFilter(parameter: 'severity', value: 'debug'));

  const AnalyticsEventSeverityFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum AnalyticsEventSourceFilter implements QueryFilterSet {
  all(null),
  backend(QueryFilter(parameter: 'source', value: 'backend')),
  frontend(QueryFilter(parameter: 'source', value: 'frontend')),
  printAgent(QueryFilter(parameter: 'source', value: 'print_agent')),
  integration(QueryFilter(parameter: 'source', value: 'integration'));

  const AnalyticsEventSourceFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum AnalyticsEventActivityScope implements QueryFilterSet {
  reviewable(QueryFilter(parameter: 'activity_scope', value: 'reviewable')),
  all(QueryFilter(parameter: 'activity_scope', value: 'all')),
  technical(QueryFilter(parameter: 'activity_scope', value: 'technical'));

  const AnalyticsEventActivityScope(this._filter);

  final QueryFilter _filter;

  @override
  Iterable<QueryFilter> get filters => [_filter];
}

enum AnalyticsEventActionFilter implements QueryFilterSet {
  all(null),
  fraudSignal(QueryFilter(parameter: 'action', value: 'fraud_signal')),
  posLineAdded(QueryFilter(parameter: 'action', value: 'pos_line_added')),
  posLineDeleted(QueryFilter(parameter: 'action', value: 'pos_line_deleted')),
  posLineQuantityChanged(
    QueryFilter(parameter: 'action', value: 'pos_line_quantity_changed'),
  ),
  posCartCleared(QueryFilter(parameter: 'action', value: 'pos_cart_cleared')),
  purchaseLineAdded(
    QueryFilter(parameter: 'action', value: 'purchase_line_added'),
  ),
  purchaseLineDeleted(
    QueryFilter(parameter: 'action', value: 'purchase_line_deleted'),
  ),
  purchaseLineQuantityChanged(
    QueryFilter(parameter: 'action', value: 'purchase_line_quantity_changed'),
  ),
  purchaseDraftCleared(
    QueryFilter(parameter: 'action', value: 'purchase_draft_cleared'),
  ),
  purchaseDraftSubmitted(
    QueryFilter(parameter: 'action', value: 'purchase_draft_submitted'),
  ),
  invoiceCreated(QueryFilter(parameter: 'action', value: 'invoice_created')),
  customerCreated(QueryFilter(parameter: 'action', value: 'customer_created')),
  registerCashMovement(
    QueryFilter(parameter: 'action', value: 'register_cash_movement'),
  ),
  registerSessionStarted(
    QueryFilter(parameter: 'action', value: 'register_session_started'),
  ),
  registerSessionClosed(
    QueryFilter(parameter: 'action', value: 'register_session_closed'),
  ),
  receiptReprinted(
    QueryFilter(parameter: 'action', value: 'receipt_reprinted'),
  ),
  orderVoided(QueryFilter(parameter: 'action', value: 'order_voided')),
  orderReturned(QueryFilter(parameter: 'action', value: 'order_returned')),
  productChanged(QueryFilter(parameter: 'action', value: 'product_changed')),
  stockMovementCreated(
    QueryFilter(parameter: 'action', value: 'stock_movement_created'),
  ),
  barcodeLabelsPrinted(
    QueryFilter(parameter: 'action', value: 'barcode_labels_printed'),
  ),
  userChanged(QueryFilter(parameter: 'action', value: 'user_changed')),
  settingsChanged(QueryFilter(parameter: 'action', value: 'settings_changed')),
  discountChanged(QueryFilter(parameter: 'action', value: 'discount_changed')),
  reportActivity(QueryFilter(parameter: 'action', value: 'report_activity')),
  printerActivity(QueryFilter(parameter: 'action', value: 'printer_activity')),
  analyticsExport(QueryFilter(parameter: 'action', value: 'analytics_export')),
  purchaseOrderDeleted(
    QueryFilter(parameter: 'action', value: 'purchase_order_deleted'),
  ),
  anyDeleted(QueryFilter(parameter: 'action', value: 'any_deleted'));

  const AnalyticsEventActionFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum AnalyticsEventDateRange { all, today, last7Days, last30Days, custom }

enum AnalyticsEventOrdering implements QueryOrdering {
  newest('-occurred_at'),
  oldest('occurred_at'),
  highestRisk('-risk_score'),
  newestReceived('-created_at');

  const AnalyticsEventOrdering(this.apiValue);

  @override
  final String apiValue;
}

class AnalyticsEventQuery extends ModelQuery {
  const AnalyticsEventQuery({
    this.search = '',
    this.type = AnalyticsEventTypeFilter.all,
    this.severity = AnalyticsEventSeverityFilter.all,
    this.source = AnalyticsEventSourceFilter.all,
    this.activityScope = AnalyticsEventActivityScope.reviewable,
    this.action = AnalyticsEventActionFilter.all,
    this.dateRange = AnalyticsEventDateRange.last7Days,
    this.occurredAfter,
    this.occurredBefore,
    this.userId,
    this.userLabel = '',
    this.userIds = const [],
    this.userLabels = const [],
    this.registerSessionId = '',
    this.entityType = '',
    this.entityId = '',
    this.minRiskScore,
    this.ordering = AnalyticsEventOrdering.newest,
  });

  @override
  final String search;
  final AnalyticsEventTypeFilter type;
  final AnalyticsEventSeverityFilter severity;
  final AnalyticsEventSourceFilter source;
  final AnalyticsEventActivityScope activityScope;
  final AnalyticsEventActionFilter action;
  final AnalyticsEventDateRange dateRange;
  final DateTime? occurredAfter;
  final DateTime? occurredBefore;
  final int? userId;
  final String userLabel;
  final List<int> userIds;
  final List<String> userLabels;
  final String registerSessionId;
  final String entityType;
  final String entityId;
  final int? minRiskScore;
  @override
  final AnalyticsEventOrdering ordering;

  List<int> get selectedUserIds {
    final ids = userIds.isNotEmpty ? userIds : [if (userId != null) userId!];
    final seen = <int>{};
    return [
      for (final id in ids)
        if (seen.add(id)) id,
    ];
  }

  List<String> get selectedUserLabels {
    final labels = userLabels.isNotEmpty
        ? userLabels
        : [if (userLabel.trim().isNotEmpty) userLabel];
    return [
      for (final label in labels)
        if (label.trim().isNotEmpty) label,
    ];
  }

  @override
  Iterable<QueryFilter> get filters => [
    ...type.filters,
    ...severity.filters,
    ...source.filters,
    ...activityScope.filters,
    ...action.filters,
  ];

  int get activeFilterCount {
    return [
      type != AnalyticsEventTypeFilter.all,
      severity != AnalyticsEventSeverityFilter.all,
      source != AnalyticsEventSourceFilter.all,
      activityScope != AnalyticsEventActivityScope.reviewable,
      action != AnalyticsEventActionFilter.all,
      dateRange != AnalyticsEventDateRange.all,
      selectedUserIds.isNotEmpty,
      registerSessionId.trim().isNotEmpty,
      entityType.trim().isNotEmpty,
      entityId.trim().isNotEmpty,
      minRiskScore != null,
    ].where((isActive) => isActive).length;
  }

  @override
  Map<String, String> toQueryParameters({required int page}) {
    final userIds = selectedUserIds;
    return {
      if (search.trim().isNotEmpty) 'search': search.trim(),
      for (final filter in filters) filter.parameter: filter.value,
      if (occurredAfter != null)
        'occurred_at_after': occurredAfter!.toUtc().toIso8601String(),
      if (occurredBefore != null)
        'occurred_at_before': occurredBefore!.toUtc().toIso8601String(),
      if (userIds.isNotEmpty) 'received_by': userIds.join(','),
      if (registerSessionId.trim().isNotEmpty)
        'session_id': registerSessionId.trim(),
      if (entityType.trim().isNotEmpty) 'entity_type': entityType.trim(),
      if (entityId.trim().isNotEmpty) 'entity_id': entityId.trim(),
      if (minRiskScore != null) 'risk_score_min': '$minRiskScore',
      'ordering': ordering.apiValue,
      'page': '$page',
    };
  }

  AnalyticsEventQuery copyWith({
    String? search,
    AnalyticsEventTypeFilter? type,
    AnalyticsEventSeverityFilter? severity,
    AnalyticsEventSourceFilter? source,
    AnalyticsEventActivityScope? activityScope,
    AnalyticsEventActionFilter? action,
    AnalyticsEventDateRange? dateRange,
    DateTime? occurredAfter,
    DateTime? occurredBefore,
    bool clearOccurredAfter = false,
    bool clearOccurredBefore = false,
    int? userId,
    bool clearUser = false,
    String? userLabel,
    List<int>? userIds,
    List<String>? userLabels,
    String? registerSessionId,
    String? entityType,
    String? entityId,
    int? minRiskScore,
    bool clearMinRiskScore = false,
    AnalyticsEventOrdering? ordering,
  }) {
    final nextUserIds = clearUser
        ? const <int>[]
        : userIds ?? (userId == null ? this.userIds : <int>[userId]);
    final nextUserLabels = clearUser
        ? const <String>[]
        : userLabels ??
              (userLabel == null ? this.userLabels : <String>[userLabel]);

    return AnalyticsEventQuery(
      search: search ?? this.search,
      type: type ?? this.type,
      severity: severity ?? this.severity,
      source: source ?? this.source,
      activityScope: activityScope ?? this.activityScope,
      action: action ?? this.action,
      dateRange: dateRange ?? this.dateRange,
      occurredAfter: clearOccurredAfter
          ? null
          : occurredAfter ?? this.occurredAfter,
      occurredBefore: clearOccurredBefore
          ? null
          : occurredBefore ?? this.occurredBefore,
      userId: clearUser
          ? null
          : userId ??
                (userIds == null
                    ? this.userId
                    : userIds.length == 1
                    ? userIds.first
                    : null),
      userLabel: clearUser
          ? ''
          : userLabel ??
                (userLabels == null
                    ? this.userLabel
                    : userLabels.length == 1
                    ? userLabels.first
                    : ''),
      userIds: nextUserIds,
      userLabels: nextUserLabels,
      registerSessionId: registerSessionId ?? this.registerSessionId,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      minRiskScore: clearMinRiskScore
          ? null
          : minRiskScore ?? this.minRiskScore,
      ordering: ordering ?? this.ordering,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AnalyticsEventQuery &&
        other.search == search &&
        other.type == type &&
        other.severity == severity &&
        other.source == source &&
        other.activityScope == activityScope &&
        other.action == action &&
        other.dateRange == dateRange &&
        other.occurredAfter == occurredAfter &&
        other.occurredBefore == occurredBefore &&
        _intListsEqual(other.selectedUserIds, selectedUserIds) &&
        _stringListsEqual(other.selectedUserLabels, selectedUserLabels) &&
        other.registerSessionId == registerSessionId &&
        other.entityType == entityType &&
        other.entityId == entityId &&
        other.minRiskScore == minRiskScore &&
        other.ordering == ordering;
  }

  @override
  int get hashCode => Object.hash(
    search,
    type,
    severity,
    source,
    activityScope,
    action,
    dateRange,
    occurredAfter,
    occurredBefore,
    Object.hashAll(selectedUserIds),
    Object.hashAll(selectedUserLabels),
    registerSessionId,
    entityType,
    entityId,
    minRiskScore,
    ordering,
  );
}

bool _intListsEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

bool _stringListsEqual(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

class AnalyticsEventPage {
  const AnalyticsEventPage({
    required this.events,
    required this.hasMore,
    required this.totalCount,
  });

  final List<AnalyticsEventRecord> events;
  final bool hasMore;
  final int totalCount;

  factory AnalyticsEventPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(AnalyticsEventRecord.fromJson)
        .toList(growable: false);
    return AnalyticsEventPage(
      events: results,
      hasMore: json['next'] != null,
      totalCount: _intFromJson(json['count']),
    );
  }
}

class AnalyticsEventRecord {
  const AnalyticsEventRecord({
    required this.id,
    required this.clientEventId,
    required this.eventType,
    required this.name,
    required this.severity,
    required this.source,
    required this.occurredAt,
    required this.attributes,
    required this.metrics,
    this.receivedBy,
    this.receivedByUsername = '',
    this.sessionId = '',
    this.deviceId = '',
    this.installationId = '',
    this.appVersion = '',
    this.platform = '',
    this.requestPath = '',
    this.ipAddress = '',
    this.userAgent = '',
    this.traceId = '',
    this.entityType = '',
    this.entityId = '',
    this.riskScore,
  });

  final int id;
  final String clientEventId;
  final AnalyticsEventType eventType;
  final String name;
  final AnalyticsEventSeverity severity;
  final AnalyticsEventSource source;
  final DateTime occurredAt;
  final int? receivedBy;
  final String receivedByUsername;
  final String sessionId;
  final String deviceId;
  final String installationId;
  final String appVersion;
  final String platform;
  final String requestPath;
  final String ipAddress;
  final String userAgent;
  final String traceId;
  final String entityType;
  final String entityId;
  final int? riskScore;
  final Map<String, Object?> attributes;
  final Map<String, Object?> metrics;

  bool get isFraudSignal => eventType == AnalyticsEventType.fraudSignal;

  bool get hasRiskScore => riskScore != null;

  String get registerSessionReference {
    final attributeSession = attributes['register_session_id'];
    if (attributeSession != null && attributeSession.toString().isNotEmpty) {
      return 'register:$attributeSession';
    }
    if (entityType == 'register_session' && entityId.isNotEmpty) {
      return 'register:$entityId';
    }
    return sessionId;
  }

  factory AnalyticsEventRecord.fromJson(Map<String, Object?> json) {
    return AnalyticsEventRecord(
      id: _intFromJson(json['id']),
      clientEventId: json['client_event_id']?.toString() ?? '',
      eventType: analyticsEventTypeFromJson(json['event_type']?.toString()),
      name: json['name']?.toString() ?? '',
      severity: analyticsEventSeverityFromJson(json['severity']?.toString()),
      source: analyticsEventSourceFromJson(json['source']?.toString()),
      occurredAt: _dateTimeFromJson(json['occurred_at']),
      receivedBy: _nullableIntFromJson(json['received_by']),
      receivedByUsername: json['received_by_username']?.toString() ?? '',
      sessionId: json['session_id']?.toString() ?? '',
      deviceId: json['device_id']?.toString() ?? '',
      installationId: json['installation_id']?.toString() ?? '',
      appVersion: json['app_version']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      requestPath: json['request_path']?.toString() ?? '',
      ipAddress: json['ip_address']?.toString() ?? '',
      userAgent: json['user_agent']?.toString() ?? '',
      traceId: json['trace_id']?.toString() ?? '',
      entityType: json['entity_type']?.toString() ?? '',
      entityId: json['entity_id']?.toString() ?? '',
      riskScore: _nullableIntFromJson(json['risk_score']),
      attributes: _objectMapFromJson(json['attributes']),
      metrics: _objectMapFromJson(json['metrics']),
    );
  }
}

String analyticsEventTypeToJson(AnalyticsEventType type) {
  return switch (type) {
    AnalyticsEventType.usage => 'usage',
    AnalyticsEventType.error => 'error',
    AnalyticsEventType.performance => 'performance',
    AnalyticsEventType.security => 'security',
    AnalyticsEventType.fraudSignal => 'fraud_signal',
    AnalyticsEventType.audit => 'audit',
  };
}

AnalyticsEventType analyticsEventTypeFromJson(String? value) {
  return switch (value) {
    'error' => AnalyticsEventType.error,
    'performance' => AnalyticsEventType.performance,
    'security' => AnalyticsEventType.security,
    'fraud_signal' => AnalyticsEventType.fraudSignal,
    'audit' => AnalyticsEventType.audit,
    _ => AnalyticsEventType.usage,
  };
}

String analyticsEventSeverityToJson(AnalyticsEventSeverity severity) {
  return switch (severity) {
    AnalyticsEventSeverity.debug => 'debug',
    AnalyticsEventSeverity.info => 'info',
    AnalyticsEventSeverity.warning => 'warning',
    AnalyticsEventSeverity.error => 'error',
    AnalyticsEventSeverity.critical => 'critical',
  };
}

AnalyticsEventSeverity analyticsEventSeverityFromJson(String? value) {
  return switch (value) {
    'debug' => AnalyticsEventSeverity.debug,
    'warning' => AnalyticsEventSeverity.warning,
    'error' => AnalyticsEventSeverity.error,
    'critical' => AnalyticsEventSeverity.critical,
    _ => AnalyticsEventSeverity.info,
  };
}

String analyticsEventSourceToJson(AnalyticsEventSource source) {
  return switch (source) {
    AnalyticsEventSource.frontend => 'frontend',
    AnalyticsEventSource.backend => 'backend',
    AnalyticsEventSource.printAgent => 'print_agent',
    AnalyticsEventSource.integration => 'integration',
  };
}

AnalyticsEventSource analyticsEventSourceFromJson(String? value) {
  return switch (value) {
    'backend' => AnalyticsEventSource.backend,
    'print_agent' => AnalyticsEventSource.printAgent,
    'integration' => AnalyticsEventSource.integration,
    _ => AnalyticsEventSource.frontend,
  };
}

String analyticsEventNameToJson(AnalyticsEventName name) {
  return switch (name) {
    AnalyticsEventName.appStarted => 'app.started',
    AnalyticsEventName.appFlutterError => 'app.flutter_error',
    AnalyticsEventName.appPlatformError => 'app.platform_error',
    AnalyticsEventName.authSessionStarted => 'auth.session_started',
    AnalyticsEventName.authLoginSucceeded => 'auth.login.succeeded',
    AnalyticsEventName.authLoginFailed => 'auth.login.failed',
    AnalyticsEventName.authLogout => 'auth.logout',
    AnalyticsEventName.frontendFrameTiming => 'frontend.frame_timing',
    AnalyticsEventName.frontendHttpRequest => 'frontend.http_request',
    AnalyticsEventName.frontendOperation => 'frontend.operation',
    AnalyticsEventName.frontendScreenViewed => 'frontend.screen_viewed',
    AnalyticsEventName.frontendInteraction => 'frontend.interaction',
    AnalyticsEventName.appLifecycleChanged => 'app.lifecycle_changed',
    AnalyticsEventName.telemetryQueueHealth => 'telemetry.queue.health',
    AnalyticsEventName.analyticsExportStarted => 'analytics.export.started',
    AnalyticsEventName.analyticsExportCompleted => 'analytics.export.completed',
    AnalyticsEventName.analyticsExportFailed => 'analytics.export.failed',
    AnalyticsEventName.analyticsExportDownloaded =>
      'analytics.export.downloaded',
    AnalyticsEventName.analyticsExportDownloadFailed =>
      'analytics.export.download_failed',
    AnalyticsEventName.reportGenerated => 'report.generated',
    AnalyticsEventName.reportGenerationFailed => 'report.generation_failed',
    AnalyticsEventName.reportPreviewed => 'report.previewed',
    AnalyticsEventName.reportPrinted => 'report.printed',
    AnalyticsEventName.reportShared => 'report.shared',
    AnalyticsEventName.posCheckoutStarted => 'pos.checkout.started',
    AnalyticsEventName.posCheckoutCompleted => 'pos.checkout.completed',
    AnalyticsEventName.posCheckoutFailed => 'pos.checkout.failed',
    AnalyticsEventName.posCheckoutStockRejected =>
      'pos.checkout.stock_rejected',
  };
}

String generateAnalyticsEventId() {
  final random = _analyticsRandom();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

Random _analyticsRandom() {
  try {
    return Random.secure();
  } on UnsupportedError {
    return Random();
  }
}

DateTime _dateTimeFromJson(Object? value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  return DateTime.now().toUtc();
}

String? _stringOrNull(Object? value) {
  final string = value?.toString();
  if (string == null || string.isEmpty) {
    return null;
  }
  return string;
}

Map<String, Object?> _objectMapFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return Map.unmodifiable(value);
  }
  if (value is Map) {
    return Map.unmodifiable(value.cast<String, Object?>());
  }
  return const {};
}

Map<String, num> _numericMapFromJson(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return Map.unmodifiable({
    for (final entry in value.entries)
      if (entry.value is num) entry.key.toString(): entry.value as num,
  });
}

List<String> _stringListFromJson(Object? value) {
  if (value is! Iterable) {
    return const [];
  }
  return value.map((item) => item.toString()).toList(growable: false);
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null || value.toString().isEmpty) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString());
}
