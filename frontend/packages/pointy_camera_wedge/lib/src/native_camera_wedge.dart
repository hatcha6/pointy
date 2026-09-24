import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'native_wedge_events.dart';

/// A running camera wedge, as the app sees it.
///
/// An interface so the app's own code can be tested with a fake instead of a
/// DLL: [NativeCameraWedge] is the real thing.
abstract interface class NativeWedgeHandle {
  /// Status changes, confirmed scans, stats about once a second, and preview
  /// frames while [setPreview] has them on.
  Stream<NativeWedgeEvent> get events;

  /// Ask for preview frames (`maxEdge > 0`) or stop them (`maxEdge <= 0`).
  void setPreview({
    required int maxEdge,
    Duration interval = const Duration(milliseconds: 100),
  });

  /// Stop the camera and free everything. Completes once the camera has been
  /// released. Safe to call more than once.
  Future<void> stop();
}

/// Whether this process can run the native wedge, and if not, why not.
class NativeWedgeAvailability {
  const NativeWedgeAvailability._(this.isAvailable, this.reason);

  final bool isAvailable;

  /// Why not, for logs and support: a missing DLL, Windows without Media
  /// Foundation (the "N" editions), an ABI mismatch.
  final String? reason;
}

/// The counter camera, run in native code (src/, loaded through FFI).
///
/// Dart hands the library a [ReceivePort]'s native port and receives
/// [NativeWedgeEvent]s on it. Not a `NativeCallable`: calling one after Dart
/// has closed it is a fatal VM error, which is exactly what a camera thread
/// would do when the app exits or hot-restarts mid-frame. A closed port just
/// makes the native side stop and release the camera (see the C header).
class NativeCameraWedge implements NativeWedgeHandle {
  NativeCameraWedge._(this._bindings, this._port, this._handle) {
    _subscription = _port.listen(_onMessage);
  }

  /// Whether the wedge can run here. Loads the library on first use.
  static NativeWedgeAvailability get availability {
    final loaded = _library;
    if (loaded.bindings == null) {
      return NativeWedgeAvailability._(false, loaded.error);
    }
    return const NativeWedgeAvailability._(true, null);
  }

  /// The cameras the OS can see, listed on a native thread.
  static Future<NativeDeviceList> listDevices({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final bindings = _library.bindings;
    if (bindings == null) {
      return NativeDeviceList(
        devices: const [],
        error: NativeWedgeError.unsupported,
        message: _library.error ?? '',
      );
    }
    final port = ReceivePort();
    try {
      if (bindings.listDevices(port.sendPort.nativePort) != 0) {
        return const NativeDeviceList(
          devices: [],
          error: NativeWedgeError.platform,
          message: 'the device listing was refused',
        );
      }
      final reply = await port
          .map(NativeDeviceList.parse)
          .firstWhere((list) => list != null)
          .timeout(timeout);
      return reply!;
    } on TimeoutException {
      return const NativeDeviceList(
        devices: [],
        error: NativeWedgeError.platform,
        message: 'listing cameras timed out',
      );
    } finally {
      port.close();
    }
  }

  /// Open a camera and start reading. Returns at once; whether the camera
  /// actually opened arrives as a [NativeWedgeStatus] on [events].
  static NativeCameraWedge start({
    String? deviceId,
    int preferredWidth = 0,
    int preferredHeight = 0,
    Duration? agreementWindow,
    Duration? rereadHoldoff,
    Duration? statsInterval,
  }) {
    final bindings = _library.bindings;
    if (bindings == null) {
      throw UnsupportedError(
          _library.error ?? 'native camera wedge unavailable');
    }
    final port = ReceivePort();
    final options = calloc<PcwOptions>();
    final id =
        deviceId == null ? nullptr : deviceId.toNativeUtf8(allocator: calloc);
    try {
      options.ref
        ..structSize = sizeOf<PcwOptions>()
        ..deviceId = id
        ..preferredWidth = preferredWidth
        ..preferredHeight = preferredHeight
        ..agreementWindowMs = agreementWindow?.inMilliseconds ?? 0
        ..rereadHoldoffMs = rereadHoldoff?.inMilliseconds ?? 0
        ..statsIntervalMs = statsInterval?.inMilliseconds ?? 0;
      // The library copies what it needs before returning.
      final handle = bindings.start(options, port.sendPort.nativePort);
      if (handle == nullptr) {
        port.close();
        throw StateError('the native camera wedge refused to start');
      }
      return NativeCameraWedge._(bindings, port, handle);
    } finally {
      calloc.free(options);
      if (id != nullptr) calloc.free(id);
    }
  }

  final CameraWedgeBindings _bindings;
  final ReceivePort _port;
  final Pointer<Void> _handle;
  late final StreamSubscription<Object?> _subscription;
  final _events = StreamController<NativeWedgeEvent>.broadcast();
  final _stopped = Completer<void>();
  Future<void>? _stopping;

  @override
  Stream<NativeWedgeEvent> get events => _events.stream;

  @override
  void setPreview({
    required int maxEdge,
    Duration interval = const Duration(milliseconds: 100),
  }) {
    if (_stopping != null) return;
    _bindings.setPreview(_handle, maxEdge, interval.inMilliseconds);
  }

  @override
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _bindings.stop(_handle);
    try {
      // The camera is released on the wedge's own thread; releasing the
      // handle before it says so would block this isolate on that thread.
      await _stopped.future.timeout(const Duration(seconds: 10));
      _bindings.release(_handle);
    } on TimeoutException {
      // A driver that will not let go. Leaking one small handle is better
      // than freezing the till waiting for it; the port is closed below, so
      // the native side stops posting and gives up the camera by itself the
      // moment it can.
    } finally {
      // Release strictly before closing the port: the library reaps wedges
      // whose port is closed, and must not find this one still registered.
      await _subscription.cancel();
      _port.close();
      await _events.close();
    }
  }

  void _onMessage(Object? message) {
    final event = NativeWedgeEvent.parse(message);
    if (event == null) return;
    if (!_events.isClosed) _events.add(event);
    if (event is NativeWedgeStatus &&
        event.state == NativeWedgeState.stopped &&
        !_stopped.isCompleted) {
      _stopped.complete();
    }
  }
}

class _LoadedLibrary {
  const _LoadedLibrary({this.bindings, this.error});

  final CameraWedgeBindings? bindings;
  final String? error;
}

// Per isolate: loading also connects the library to this isolate's VM API.
final _LoadedLibrary _library = _load();

_LoadedLibrary _load() {
  final DynamicLibrary library;
  try {
    library = _open();
  } on Object catch (error) {
    // The DLL is missing, or Windows could not load what it links against —
    // on the "N" editions of Windows that is Media Foundation itself, until
    // the Media Feature Pack is installed.
    return _LoadedLibrary(error: 'could not load the camera library: $error');
  }
  try {
    final bindings = CameraWedgeBindings(library);
    final version = bindings.abiVersion();
    if (version != pcwAbiVersion) {
      return _LoadedLibrary(
        error: 'camera library ABI $version, expected $pcwAbiVersion',
      );
    }
    if (bindings.initialize(NativeApi.initializeApiDLData) != 0) {
      return const _LoadedLibrary(
        error: 'the camera library could not connect to the Dart VM',
      );
    }
    if (bindings.isSupported() != 1) {
      return const _LoadedLibrary(
        error: 'no camera backend on this platform',
      );
    }
    return _LoadedLibrary(bindings: bindings);
  } on Object catch (error) {
    return _LoadedLibrary(error: 'camera library is incomplete: $error');
  }
}

DynamicLibrary _open() {
  // Tests point at a build of their own (with the synthetic camera); a
  // release build never looks at the environment for code to load.
  const product = bool.fromEnvironment('dart.vm.product');
  final override =
      product ? null : Platform.environment['POINTY_CAMERA_WEDGE_LIBRARY'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isWindows) return DynamicLibrary.open('pointy_camera_wedge.dll');
  if (Platform.isLinux) return DynamicLibrary.open('libpointy_camera_wedge.so');
  throw UnsupportedError(
    'no native camera wedge for ${Platform.operatingSystem}',
  );
}
