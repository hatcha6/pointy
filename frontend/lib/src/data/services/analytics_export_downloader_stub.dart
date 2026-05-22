import '../models/analytics_export.dart';

Future<bool> downloadAnalyticsExportFilePlatform(
  AnalyticsExportFile file,
) async {
  return file.bytes.isNotEmpty;
}
