import 'dart:typed_data';

import 'camera_file_saver_stub.dart'
    if (dart.library.html) 'camera_file_saver_web.dart';

enum CameraSaveStatus { saved, canceled, failed }

class CameraSaveResult {
  const CameraSaveResult.saved({this.location})
    : status = CameraSaveStatus.saved;
  const CameraSaveResult.canceled()
    : status = CameraSaveStatus.canceled,
      location = null;
  const CameraSaveResult.failed()
    : status = CameraSaveStatus.failed,
      location = null;

  final CameraSaveStatus status;

  /// Where the file landed, when the platform can say. Null on the web.
  final String? location;

  bool get isSaved => status == CameraSaveStatus.saved;
  bool get isCanceled => status == CameraSaveStatus.canceled;
}

/// Saves an exported clip, spooling it to disk as it arrives.
///
/// Streamed rather than buffered on purpose: a ten-minute clip off a main
/// stream is tens of megabytes, and holding that in a till's memory next to the
/// catalogue is how a cheap Windows machine starts swapping mid-shift.
Future<CameraSaveResult> saveCameraClip({
  required Stream<List<int>> bytes,
  required String filename,
  String? dialogTitle,
}) {
  return saveCameraClipPlatform(
    bytes: bytes,
    filename: filename,
    dialogTitle: dialogTitle,
  );
}

/// Saves a single still. Small enough to pass as bytes on every platform.
Future<CameraSaveResult> saveCameraStill({
  required Uint8List bytes,
  required String filename,
  String? dialogTitle,
}) {
  return saveCameraStillPlatform(
    bytes: bytes,
    filename: filename,
    dialogTitle: dialogTitle,
  );
}
