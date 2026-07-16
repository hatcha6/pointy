import '../models/analytics_export.dart';
import 'analytics_export_downloader_stub.dart'
    if (dart.library.html) 'analytics_export_downloader_web.dart';

/// Hands the exported tracking file to the platform so the user can keep it.
///
/// On desktop this opens a native "Save as…" dialog seeded with [dialogTitle],
/// letting the user pick where the file lands; on mobile it writes the file and
/// reports the path; on the web it triggers a browser download. The returned
/// [AnalyticsExportSaveResult] tells the caller whether it was saved, canceled,
/// or failed — and where it went.
Future<AnalyticsExportSaveResult> downloadAnalyticsExportFile(
  AnalyticsExportFile file, {
  String? dialogTitle,
}) {
  return downloadAnalyticsExportFilePlatform(file, dialogTitle: dialogTitle);
}
