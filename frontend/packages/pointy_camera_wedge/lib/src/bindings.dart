// The C ABI of src/include/pointy_camera_wedge.h, by hand: eight functions do
// not justify a code generator, and a mismatch shows up at once as a lookup
// failure or a wrong PCW_ABI_VERSION.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `pcw_options`. Field order and types must match the C struct exactly.
final class PcwOptions extends Struct {
  @Int32()
  external int structSize;

  external Pointer<Utf8> deviceId;

  @Int32()
  external int preferredWidth;

  @Int32()
  external int preferredHeight;

  @Int32()
  external int agreementWindowMs;

  @Int32()
  external int rereadHoldoffMs;

  @Int32()
  external int statsIntervalMs;
}

/// The version of the C ABI this Dart code speaks (PCW_ABI_VERSION).
const int pcwAbiVersion = 1;

class CameraWedgeBindings {
  CameraWedgeBindings(DynamicLibrary library)
      : abiVersion = library.lookupFunction<Int32 Function(), int Function()>(
          'pcw_abi_version',
        ),
        initialize = library.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('pcw_initialize'),
        isSupported = library.lookupFunction<Int32 Function(), int Function()>(
          'pcw_is_supported',
        ),
        listDevices =
            library.lookupFunction<Int32 Function(Int64), int Function(int)>(
          'pcw_list_devices',
        ),
        start = library.lookupFunction<
            Pointer<Void> Function(Pointer<PcwOptions>, Int64),
            Pointer<Void> Function(Pointer<PcwOptions>, int)>('pcw_start'),
        setPreview = library.lookupFunction<
            Void Function(Pointer<Void>, Int32, Int32),
            void Function(Pointer<Void>, int, int)>('pcw_set_preview'),
        stop = library.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('pcw_stop'),
        release = library.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('pcw_release');

  final int Function() abiVersion;
  final int Function(Pointer<Void> dartApiData) initialize;
  final int Function() isSupported;
  final int Function(int replyPort) listDevices;
  final Pointer<Void> Function(Pointer<PcwOptions> options, int eventPort)
      start;
  final void Function(Pointer<Void> wedge, int maxEdge, int intervalMs)
      setPreview;
  final void Function(Pointer<Void> wedge) stop;
  final void Function(Pointer<Void> wedge) release;
}
