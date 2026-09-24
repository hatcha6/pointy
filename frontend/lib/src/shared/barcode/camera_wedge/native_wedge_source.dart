/// The native camera wedge, reachable from code that also builds for the web.
///
/// `packages/pointy_camera_wedge` is `dart:ffi` through and through, and the
/// web has no FFI; the stub answers "not available" there instead.
library;

export 'native_wedge_source_stub.dart'
    if (dart.library.ffi) 'native_wedge_source_io.dart';
