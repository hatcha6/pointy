// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

import '../models/analytics_export.dart';

Future<bool> downloadAnalyticsExportFilePlatform(
  AnalyticsExportFile file,
) async {
  if (file.bytes.isEmpty) {
    return false;
  }

  final blob = html.Blob([Uint8List.fromList(file.bytes)], file.contentType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = file.filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return true;
}
