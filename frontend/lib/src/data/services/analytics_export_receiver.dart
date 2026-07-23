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
Future<AnalyticsExportFile> receiveAnalyticsExport(
  http.StreamedResponse response, {
  required String filename,
  required String contentType,
}) {
  return receiveAnalyticsExportPlatform(
    response,
    filename: filename,
    contentType: contentType,
  );
}
