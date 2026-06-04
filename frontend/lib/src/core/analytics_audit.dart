import 'dart:async';

import '../data/models/analytics_event.dart';
import 'analytics_engine.dart';

void trackAuditEvent(
  AnalyticsEngine? analyticsEngine, {
  required String name,
  AnalyticsEventSeverity severity = AnalyticsEventSeverity.info,
  String? sessionId,
  String? entityType,
  Object? entityId,
  Map<String, Object?> attributes = const {},
  Map<String, num> metrics = const {},
  bool flushImmediately = false,
}) {
  if (analyticsEngine == null) {
    return;
  }

  unawaited(
    analyticsEngine.track(
      AnalyticsEventDraft.audit(
        name: name,
        severity: severity,
        sessionId: sessionId,
        entityType: entityType,
        entityId: entityId?.toString(),
        attributes: attributes,
        metrics: metrics,
      ),
      flushImmediately: flushImmediately,
    ),
  );
}
