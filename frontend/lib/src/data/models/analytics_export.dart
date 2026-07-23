import 'dart:typed_data';

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

/// The exported tracking archive, carried either as a temp file on disk
/// (native platforms — the download streams straight to disk so an export of
/// any size never has to fit in the app's memory) or as bytes (web, where the
/// browser download needs a blob).
class AnalyticsExportFile {
  const AnalyticsExportFile.spooled({
    required String this.tempFilePath,
    required this.filename,
    required this.contentType,
    required this.sizeBytes,
  }) : bytes = null;

  const AnalyticsExportFile.inMemory({
    required Uint8List this.bytes,
    required this.filename,
    required this.contentType,
    required this.sizeBytes,
  }) : tempFilePath = null;

  /// Web only: the whole archive. `null` on native platforms.
  final Uint8List? bytes;

  /// Native platforms: where the streamed download landed. `null` on web.
  final String? tempFilePath;

  final String filename;
  final String contentType;
  final int sizeBytes;
}

/// Outcome of handing an [AnalyticsExportFile] to the platform so the user can
/// keep it. `canceled` means the user dismissed the save dialog (not an error).
enum AnalyticsExportSaveStatus { saved, canceled, failed }

class AnalyticsExportSaveResult {
  const AnalyticsExportSaveResult.saved({this.location})
    : status = AnalyticsExportSaveStatus.saved;
  const AnalyticsExportSaveResult.canceled()
    : status = AnalyticsExportSaveStatus.canceled,
      location = null;
  const AnalyticsExportSaveResult.failed()
    : status = AnalyticsExportSaveStatus.failed,
      location = null;

  final AnalyticsExportSaveStatus status;

  /// Absolute path the file was written to, when the platform can report one
  /// (desktop/mobile). `null` on the web, where the browser owns the download.
  final String? location;

  bool get isSaved => status == AnalyticsExportSaveStatus.saved;
  bool get isCanceled => status == AnalyticsExportSaveStatus.canceled;
}

enum AnalyticsExportFormat { csv, json }

String analyticsExportFormatToJson(AnalyticsExportFormat format) {
  return switch (format) {
    AnalyticsExportFormat.csv => 'csv',
    AnalyticsExportFormat.json => 'json',
  };
}
