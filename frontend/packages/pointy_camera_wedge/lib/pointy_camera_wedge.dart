/// The counter camera as a barcode wedge, run in native code.
///
/// Capture, zxing-cpp decoding and the confirmation policy all run on native
/// threads (see `src/`); Dart starts a [NativeCameraWedge] and receives
/// [NativeWedgeEvent]s — confirmed scans, status, stats and, on request,
/// preview frames.
///
/// Imports `dart:ffi`: reach it through a conditional import from code that
/// also builds for the web.
library;

export 'src/native_camera_wedge.dart';
export 'src/native_wedge_events.dart';
