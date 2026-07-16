import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../models/analytics_export.dart';

/// Native platforms (desktop + mobile): open a "Save as…" dialog so the user
/// chooses where the exported tracking file goes, then write the bytes there.
///
/// On desktop this shows the OS file dialog and writes to the chosen path; on
/// mobile it saves the file and returns the resulting path. Returning `null`
/// means the user dismissed the dialog.
Future<AnalyticsExportSaveResult> downloadAnalyticsExportFilePlatform(
  AnalyticsExportFile file, {
  String? dialogTitle,
}) async {
  if (file.bytes.isEmpty) {
    return const AnalyticsExportSaveResult.failed();
  }

  final extension = _extensionOf(file.filename);
  try {
    final savedPath = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: file.filename,
      type: extension == null ? FileType.any : FileType.custom,
      allowedExtensions: extension == null ? null : [extension],
      bytes: Uint8List.fromList(file.bytes),
    );
    if (savedPath == null) {
      return const AnalyticsExportSaveResult.canceled();
    }
    return AnalyticsExportSaveResult.saved(location: savedPath);
  } catch (_) {
    return const AnalyticsExportSaveResult.failed();
  }
}

String? _extensionOf(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) {
    return null;
  }
  return filename.substring(dot + 1);
}
