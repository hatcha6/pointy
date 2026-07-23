import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/analytics_export.dart';

/// Native platforms (desktop + mobile): open a "Save as…" dialog so the user
/// chooses where the exported tracking file goes.
///
/// The export arrives spooled in a temp file (see the receiver), so on desktop
/// saving is a rename/copy of that file — the archive is never loaded into
/// memory, whatever its size. Mobile's save dialog writes bytes itself, so
/// only there the file is read back once. Returning `null` from the dialog
/// means the user dismissed it.
Future<AnalyticsExportSaveResult> downloadAnalyticsExportFilePlatform(
  AnalyticsExportFile file, {
  String? dialogTitle,
}) async {
  final tempPath = file.tempFilePath;
  if (tempPath == null) {
    return const AnalyticsExportSaveResult.failed();
  }
  // Sync file I/O throughout: instant for a rename, and it keeps this flow
  // working under the widget tests' fake-async zone (real I/O futures stall).
  final tempFile = File(tempPath);
  if (!tempFile.existsSync() || file.sizeBytes == 0) {
    return const AnalyticsExportSaveResult.failed();
  }

  final extension = _extensionOf(file.filename);
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: the platform's save flow writes the bytes itself.
      final savedPath = await FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: file.filename,
        type: extension == null ? FileType.any : FileType.custom,
        allowedExtensions: extension == null ? null : [extension],
        bytes: tempFile.readAsBytesSync(),
      );
      if (savedPath == null) {
        return const AnalyticsExportSaveResult.canceled();
      }
      return AnalyticsExportSaveResult.saved(location: savedPath);
    }

    // Desktop: the dialog only picks the destination; move the spooled file
    // there without ever reading it into memory.
    final savedPath = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: file.filename,
      type: extension == null ? FileType.any : FileType.custom,
      allowedExtensions: extension == null ? null : [extension],
    );
    if (savedPath == null) {
      return const AnalyticsExportSaveResult.canceled();
    }
    try {
      tempFile.renameSync(savedPath);
    } on FileSystemException {
      // Destination on another volume: rename can't cross it, copy can.
      tempFile.copySync(savedPath);
    }
    return AnalyticsExportSaveResult.saved(location: savedPath);
  } catch (_) {
    return const AnalyticsExportSaveResult.failed();
  } finally {
    if (tempFile.existsSync()) {
      try {
        tempFile.deleteSync();
      } catch (_) {
        // A leaked temp file is not worth failing the save over.
      }
    }
  }
}

String? _extensionOf(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) {
    return null;
  }
  return filename.substring(dot + 1);
}
