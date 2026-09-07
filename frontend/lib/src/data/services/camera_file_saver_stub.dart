import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_file_saver.dart';

/// Native platforms: spool the clip to a temp file first, then let the user
/// choose where it goes.
///
/// Spooling is what keeps the export off the heap — the file is written as the
/// bytes arrive and, on desktop, moved to its destination without ever being
/// read back.
Future<CameraSaveResult> saveCameraClipPlatform({
  required Stream<List<int>> bytes,
  required String filename,
  String? dialogTitle,
}) async {
  File? spool;
  try {
    final directory = await getTemporaryDirectory();
    spool = File(
      '${directory.path}/pointy-clip-'
      '${DateTime.now().millisecondsSinceEpoch}-$filename',
    );
    final sink = spool.openWrite();
    try {
      await sink.addStream(bytes);
    } finally {
      await sink.close();
    }
    if (!spool.existsSync() || spool.lengthSync() == 0) {
      return const CameraSaveResult.failed();
    }
    return await _offerToSave(spool, filename, dialogTitle, 'mp4');
  } on Object {
    return const CameraSaveResult.failed();
  } finally {
    // The spool is a copy; whether the save succeeded or the user cancelled,
    // leaving it behind would fill a till's temp directory one clip at a time.
    try {
      if (spool != null && spool.existsSync()) {
        spool.deleteSync();
      }
    } on Object {
      // Nothing useful to do about a temp file we cannot delete.
    }
  }
}

Future<CameraSaveResult> saveCameraStillPlatform({
  required Uint8List bytes,
  required String filename,
  String? dialogTitle,
}) async {
  if (bytes.isEmpty) {
    return const CameraSaveResult.failed();
  }
  try {
    final savedPath = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: const ['jpg'],
      bytes: bytes,
    );
    if (savedPath == null) {
      return const CameraSaveResult.canceled();
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      // Desktop's dialog only picks a destination; it does not write.
      File(savedPath).writeAsBytesSync(bytes);
    }
    return CameraSaveResult.saved(location: savedPath);
  } on Object {
    return const CameraSaveResult.failed();
  }
}

Future<CameraSaveResult> _offerToSave(
  File spool,
  String filename,
  String? dialogTitle,
  String extension,
) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final savedPath = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: spool.readAsBytesSync(),
    );
    if (savedPath == null) {
      return const CameraSaveResult.canceled();
    }
    return CameraSaveResult.saved(location: savedPath);
  }

  final savedPath = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: filename,
    type: FileType.custom,
    allowedExtensions: [extension],
  );
  if (savedPath == null) {
    return const CameraSaveResult.canceled();
  }
  spool.copySync(savedPath);
  return CameraSaveResult.saved(location: savedPath);
}
