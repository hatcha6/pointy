import 'snapshot_decoder.dart';

/// The web never reaches here: `CameraWedgeController.backend` resolves to
/// `platformScanner` where `mobile_scanner` exists and `none` otherwise, and
/// the snapshot backend is offered on Windows and Linux only. This half of the
/// seam exists so the file that needs `dart:io` never enters a web compile.
Future<SnapshotDecode> decodeSnapshotPlatform(
  String path, {
  required int maxSize,
}) async => SnapshotDecode.failed(
  UnsupportedError('The snapshot camera wedge does not run on the web.'),
);
