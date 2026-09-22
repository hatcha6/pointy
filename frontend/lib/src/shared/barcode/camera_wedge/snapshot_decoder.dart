/// Turning one still into a decode, off the thread that draws the till.
///
/// Every step of `flutter_zxing`'s file path is blocking work, and all of it
/// used to run on the UI isolate — read out of the package rather than
/// assumed (`lib/src/logic/barcode_reader.dart`):
///
/// ```dart
/// final Uint8List imageBytes = await path.readAsBytes();
/// imglib.Image? image = imglib.decodeImage(imageBytes);   // pure-Dart JPEG decode
/// image = resizeToMaxSize(image, params.maxSize);         // pure-Dart resize
/// return zxingReadBarcode(rgbBytes(image), params);       // blocking FFI
/// ```
///
/// A pure-Dart JPEG decode of a full-resolution still is hundreds of
/// milliseconds, the RGB conversion allocates the whole frame again, and the
/// zxing call itself is synchronous FFI that returns only when it has finished
/// looking. Run back to back on the UI isolate that is most of every second
/// spent not drawing, which is exactly what a shop reported after switching
/// the counter camera on.
///
/// So the work goes to a worker isolate through `compute`. The seam is a
/// conditional import because the implementation needs `dart:io` to delete the
/// still afterwards, and this file is reachable from the web build.
library;

import 'snapshot_decoder_io.dart'
    if (dart.library.html) 'snapshot_decoder_web.dart';

/// What one still came back with: a code, nothing, or a reason.
class SnapshotDecode {
  const SnapshotDecode.read({required this.value, required this.symbology})
    : error = null;

  const SnapshotDecode.blank() : value = null, symbology = null, error = null;

  const SnapshotDecode.failed(this.error) : value = null, symbology = null;

  /// The decoded text, when there was one.
  final String? value;

  /// The symbology name as zxing spells it (`EAN13`, `QRCode`, …).
  final String? symbology;

  /// Why nothing came back, when the reason was a failure rather than a still
  /// with no barcode in it. Kept apart from [SnapshotDecode.blank] because a
  /// camera that cannot take a picture at all and a camera pointed at an empty
  /// counter look identical otherwise — which is how a broken camera spent a
  /// shift claiming to work.
  final Object? error;

  bool get isRead => value != null && value!.isNotEmpty;
  bool get isFailure => error != null;
}

/// Decode the still at [path] and delete it, whatever the outcome.
///
/// Deleting is not tidiness. `camera_windows` writes every `takePicture` into
/// the user's **Pictures** folder — `SHGetKnownFolderPath(FOLDERID_Pictures)`
/// in `camera_plugin.cpp`, named `PhotoCapture_<timestamp>.jpeg` — and nothing
/// removes it. That is roughly one full-resolution JPEG per second for as long
/// as the wedge is on: a few thousand an hour, in the folder Windows Search
/// indexes and OneDrive syncs.
Future<SnapshotDecode> decodeSnapshot(String path, {required int maxSize}) =>
    decodeSnapshotPlatform(path, maxSize: maxSize);
