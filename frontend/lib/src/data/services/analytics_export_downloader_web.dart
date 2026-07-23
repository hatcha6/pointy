// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import '../models/analytics_export.dart';

/// Web: trigger a browser download. The browser owns the destination folder, so
/// there is no path to report back ([AnalyticsExportSaveResult.location] stays
/// `null`). [dialogTitle] is unused here — the browser has no save dialog.
Future<AnalyticsExportSaveResult> downloadAnalyticsExportFilePlatform(
  AnalyticsExportFile file, {
  String? dialogTitle,
}) async {
  if (file.bytes.isEmpty) {
    return const AnalyticsExportSaveResult.failed();
  }

  final blob = html.Blob([file.bytes], file.contentType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = file.filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return const AnalyticsExportSaveResult.saved();
}
