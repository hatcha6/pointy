import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Asks the desktop "Save as…" dialog for a destination, without handing it
/// the file.
///
/// file_picker writes whatever bytes it is given to the chosen path, so it is
/// given none: the dialog leaves an empty file there, and the caller moves or
/// copies the real one over it. A large spooled export or recording is never
/// read into memory. Returns `null` when the dialog is dismissed.
Future<String?> pickDesktopSaveDestination({
  required String fileName,
  String? dialogTitle,
  List<String>? allowedExtensions,
}) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: allowedExtensions == null ? FileType.any : FileType.custom,
    allowedExtensions: allowedExtensions,
    bytes: Uint8List(0),
  );
  return uri?.toFilePath();
}

/// What to show the user for a saved file: its path when it has one, else the
/// platform's own reference to it (an Android `content://` document).
String savedLocationLabel(Uri uri) =>
    uri.isScheme('file') ? uri.toFilePath() : Uri.decodeFull(uri.toString());

/// A picked file's bytes, or `null` when it cannot be read (or is empty) —
/// the case the pickers' own "could not read the file" messages cover.
Future<Uint8List?> readPickedBytes(PlatformFile file) async {
  try {
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  } on Exception {
    return null;
  }
}
