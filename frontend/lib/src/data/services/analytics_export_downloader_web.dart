import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../models/analytics_export.dart';

/// Web: trigger a browser download. The browser owns the destination folder, so
/// there is no path to report back ([AnalyticsExportSaveResult.location] stays
/// `null`). [dialogTitle] is unused here — the browser has no save dialog.
Future<AnalyticsExportSaveResult> downloadAnalyticsExportFilePlatform(
  AnalyticsExportFile file, {
  String? dialogTitle,
}) async {
  final bytes = file.bytes;
  if (bytes == null || bytes.isEmpty) {
    return const AnalyticsExportSaveResult.failed();
  }

  saveBytesInBrowser([bytes], file.filename, file.contentType);
  return const AnalyticsExportSaveResult.saved();
}

/// Hands [parts] to the browser as one download named [filename]. The browser
/// owns the destination folder.
void saveBytesInBrowser(
  List<List<int>> parts,
  String filename,
  String contentType,
) {
  final blob = web.Blob(
    [
      for (final part in parts)
        (part is Uint8List ? part : Uint8List.fromList(part)).toJS,
    ].toJS,
    web.BlobPropertyBag(type: contentType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
