import 'dart:async';
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
      // No 'ordering': the export deliberately does not sort. Sorting a whole
      // month of telemetry is a scan and a sort of everything before the first
      // byte can be sent; rows come back in physical (roughly insertion) order
      // instead, and anything that needs them sorted can sort the file.
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

/// `jsonl` is newline-delimited JSON — one document per line. It is the format
/// to reach for on a large export: every streaming tool reads it a line at a
/// time, where a single JSON array has to be parsed whole before anything can
/// look at the first record.
enum AnalyticsExportFormat { csv, json, jsonl }

String analyticsExportFormatToJson(AnalyticsExportFormat format) {
  return switch (format) {
    AnalyticsExportFormat.csv => 'csv',
    AnalyticsExportFormat.json => 'json',
    AnalyticsExportFormat.jsonl => 'jsonl',
  };
}

/// How far along a running export is.
///
/// An export of a month of telemetry is a real download, not a blink: without
/// this the button just spins and the only honest thing the user can conclude
/// is that it has hung. [expectedEventCount] is the server's planner estimate
/// (from `X-Pointy-Analytics-Event-Count-Estimate`) — deliberately approximate,
/// because an exact count would mean scanning the table before sending a byte.
class AnalyticsExportProgress {
  const AnalyticsExportProgress({
    required this.receivedBytes,
    required this.elapsed,
    this.expectedEventCount,
  });

  final int receivedBytes;
  final Duration elapsed;
  final int? expectedEventCount;

  /// Compressed bytes per second, averaged over the download so far.
  double get bytesPerSecond {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    return seconds <= 0 ? 0 : receivedBytes / seconds;
  }
}

/// Lets the user stop an export that is taking longer than they want to wait.
///
/// Canceling closes the response stream, which drops the connection and lets
/// the server abandon its query, and deletes the half-written spool file.
class AnalyticsExportCancellation {
  final Completer<void> _completer = Completer<void>();

  bool get isCanceled => _completer.isCompleted;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Thrown when the user cancels a running export; not an error to report.
class AnalyticsExportCanceledException implements Exception {
  const AnalyticsExportCanceledException();

  @override
  String toString() => 'AnalyticsExportCanceledException';
}
