import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/analytics_export.dart';

/// Web: the browser download needs a blob, so collect the bytes. The browser
/// tab's memory is the platform's concern here — there is no filesystem to
/// spool to. Chunks are accumulated one at a time rather than through
/// `toBytes()` so progress can be reported and a cancel can take effect.
Future<AnalyticsExportFile> receiveAnalyticsExportPlatform(
  http.StreamedResponse response, {
  required String filename,
  required String contentType,
  void Function(int receivedBytes)? onProgress,
  AnalyticsExportCancellation? cancellation,
}) async {
  final builder = BytesBuilder(copy: false);
  var canceled = false;
  await for (final chunk in response.stream) {
    if (cancellation?.isCanceled ?? false) {
      canceled = true;
      break;
    }
    builder.add(chunk);
    onProgress?.call(builder.length);
  }
  if (canceled) {
    throw const AnalyticsExportCanceledException();
  }
  final bytes = builder.takeBytes();
  return AnalyticsExportFile.inMemory(
    bytes: bytes,
    filename: filename,
    contentType: contentType,
    sizeBytes: bytes.length,
  );
}
