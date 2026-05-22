import 'dart:math';

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
      'attributes': attributes,
      'metrics': metrics,
    };
  }
}

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
