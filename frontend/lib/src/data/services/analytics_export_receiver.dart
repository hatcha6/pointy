import 'package:http/http.dart' as http;

import '../models/analytics_export.dart';
import 'analytics_export_receiver_stub.dart'
    if (dart.library.html) 'analytics_export_receiver_web.dart';

/// Materializes a streamed export response into an [AnalyticsExportFile].
///
/// Native platforms spool the body to a temp file chunk by chunk, so an export
/// of any size downloads in constant memory; web collects bytes (the browser
/// blob needs them). Either way the response stream is fully drained (or the
/// error propagated) before this returns.
///
/// [onProgress] is called as bytes land, so the UI can show a download that
/// may run for minutes rather than an indefinite spinner. [cancellation] lets
/// the user stop it: the stream is closed, the partial file removed, and an
/// [AnalyticsExportCanceledException] thrown.
Future<AnalyticsExportFile> receiveAnalyticsExport(
  http.StreamedResponse response, {
  required String filename,
  required String contentType,
  void Function(int receivedBytes)? onProgress,
  AnalyticsExportCancellation? cancellation,
}) {
  return receiveAnalyticsExportPlatform(
    response,
    filename: filename,
    contentType: contentType,
    onProgress: onProgress,
    cancellation: cancellation,
  );
}
