import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/analytics_export.dart';

/// Native platforms: spool the export body straight to a temp file. The zip
/// never exists whole in app memory — a server-side streamed export can be
/// hundreds of MB on a busy shop, which buffering (the old `bodyBytes` path)
/// turned into an app-killing allocation right at the finish line.
///
/// Writes are synchronous per chunk: a 64KB write is microseconds on any disk
/// this app ships to, and sync I/O keeps the receiver usable under the widget
/// tests' fake-async zone, where real I/O futures never complete.
Future<AnalyticsExportFile> receiveAnalyticsExportPlatform(
  http.StreamedResponse response, {
  required String filename,
  required String contentType,
}) async {
  final directory = await _spoolDirectory();
  final tempFile = File(
    '${directory.path}${Platform.pathSeparator}'
    'pointy-export-${DateTime.now().millisecondsSinceEpoch}-$filename',
  );
  final sink = tempFile.openSync(mode: FileMode.writeOnly);
  var sizeBytes = 0;
  try {
    await for (final chunk in response.stream) {
      sink.writeFromSync(chunk);
      sizeBytes += chunk.length;
    }
  } catch (_) {
    sink.closeSync();
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
    rethrow;
  }
  sink.closeSync();
  return AnalyticsExportFile.spooled(
    tempFilePath: tempFile.path,
    filename: filename,
    contentType: contentType,
    sizeBytes: sizeBytes,
  );
}

Future<Directory> _spoolDirectory() {
  if (Platform.isAndroid || Platform.isIOS) {
    // App cache dir — the only reliably writable temp location on mobile.
    return getTemporaryDirectory();
  }
  // Desktop: the OS temp dir needs no plugin — which also keeps this flow
  // working in widget tests, where platform-channel calls never complete.
  return Future.value(Directory.systemTemp);
}
