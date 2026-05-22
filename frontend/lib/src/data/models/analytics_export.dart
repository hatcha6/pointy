class AnalyticsExportQuery {
  const AnalyticsExportQuery({
    this.format = AnalyticsExportFormat.csv,
    this.occurredFrom,
    this.occurredTo,
    this.eventType = '',
    this.severity = '',
    this.source = '',
    this.platform = '',
    this.sessionId = '',
    this.deviceId = '',
    this.search = '',
  });

  final AnalyticsExportFormat format;
  final DateTime? occurredFrom;
  final DateTime? occurredTo;
  final String eventType;
  final String severity;
  final String source;
  final String platform;
  final String sessionId;
  final String deviceId;
  final String search;

  Map<String, String> toQueryParameters() {
    return {
      'format': analyticsExportFormatToJson(format),
      if (occurredFrom != null)
        'occurred_at_after': occurredFrom!.toUtc().toIso8601String(),
      if (occurredTo != null)
        'occurred_at_before': occurredTo!.toUtc().toIso8601String(),
      if (eventType.trim().isNotEmpty) 'event_type': eventType.trim(),
      if (severity.trim().isNotEmpty) 'severity': severity.trim(),
      if (source.trim().isNotEmpty) 'source': source.trim(),
      if (platform.trim().isNotEmpty) 'platform': platform.trim(),
      if (sessionId.trim().isNotEmpty) 'session_id': sessionId.trim(),
      if (deviceId.trim().isNotEmpty) 'device_id': deviceId.trim(),
      if (search.trim().isNotEmpty) 'search': search.trim(),
      'ordering': '-occurred_at',
    };
  }

  Map<String, Object?> toAnalyticsAttributes() {
    return {
      'format': analyticsExportFormatToJson(format),
      'has_date_from': occurredFrom != null,
      'has_date_to': occurredTo != null,
      if (eventType.trim().isNotEmpty) 'event_type': eventType.trim(),
      if (severity.trim().isNotEmpty) 'severity': severity.trim(),
      if (source.trim().isNotEmpty) 'source': source.trim(),
      'platform_filtered': platform.trim().isNotEmpty,
      'session_filtered': sessionId.trim().isNotEmpty,
      'device_filtered': deviceId.trim().isNotEmpty,
      'search_filtered': search.trim().isNotEmpty,
    };
  }
}

class AnalyticsExportFile {
  const AnalyticsExportFile({
    required this.bytes,
    required this.filename,
    required this.contentType,
  });

  final List<int> bytes;
  final String filename;
  final String contentType;
}

enum AnalyticsExportFormat { csv, json }

String analyticsExportFormatToJson(AnalyticsExportFormat format) {
  return switch (format) {
    AnalyticsExportFormat.csv => 'csv',
    AnalyticsExportFormat.json => 'json',
  };
}
