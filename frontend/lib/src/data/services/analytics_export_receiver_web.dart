import 'package:http/http.dart' as http;

import '../models/analytics_export.dart';

/// Web: the browser download needs a blob, so collect the bytes. The browser
/// tab's memory is the platform's concern here — there is no filesystem to
/// spool to.
Future<AnalyticsExportFile> receiveAnalyticsExportPlatform(
  http.StreamedResponse response, {
  required String filename,
  required String contentType,
}) async {
  final bytes = await response.stream.toBytes();
  return AnalyticsExportFile.inMemory(
    bytes: bytes,
    filename: filename,
    contentType: contentType,
    sizeBytes: bytes.length,
  );
}
