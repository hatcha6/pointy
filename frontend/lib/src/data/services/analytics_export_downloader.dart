import '../models/analytics_export.dart';
import 'analytics_export_downloader_stub.dart'
    if (dart.library.html) 'analytics_export_downloader_web.dart';

Future<bool> downloadAnalyticsExportFile(AnalyticsExportFile file) {
  return downloadAnalyticsExportFilePlatform(file);
}
