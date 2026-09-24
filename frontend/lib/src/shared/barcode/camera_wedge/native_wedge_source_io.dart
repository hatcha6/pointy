import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pointy_camera_wedge/pointy_camera_wedge.dart';

import 'camera_wedge_health.dart';
import 'camera_wedge_policy.dart';
import 'camera_wedge_source.dart';

/// Whether the native wedge library loads and has a camera backend here.
bool get nativeCameraWedgeAvailable =>
    NativeCameraWedge.availability.isAvailable;

/// Why not, for logs: a missing DLL, Windows without Media Foundation.
String? get nativeCameraWedgeUnavailableReason =>
    NativeCameraWedge.availability.reason;

CameraWedgeSource? createNativeWedgeSource() => NativeWedgeSource();

typedef NativeWedgeStarter = NativeWedgeHandle Function({String? deviceId});
typedef NativeDeviceLister = Future<NativeDeviceList> Function();

/// The counter camera through `packages/pointy_camera_wedge`: capture,
/// zxing-cpp and the confirmation policy all run in native code, and what
/// arrives here is already a scan a till may act on.
///
/// This class only translates: native events into the app's
/// [CameraWedgeScan]/[CameraWedgeHealth]/[CameraWedgePreviewFrame], and
/// the app's preview requests into the library's.
class NativeWedgeSource implements CameraWedgeSource {
  NativeWedgeSource({
    NativeWedgeStarter? starter,
    NativeDeviceLister? lister,
    DateTime Function()? clock,
  }) : _starter = starter ?? _startNative,
       _lister = lister ?? NativeCameraWedge.listDevices,
       _clock = clock ?? DateTime.now;

  /// Sharp enough to judge focus and aim by eye, small enough to cost
  /// nothing: 480x270 grey at ten frames a second is 1.3 MB/s.
  static const previewMaxEdge = 480;
  static const previewInterval = Duration(milliseconds: 100);

  static NativeWedgeHandle _startNative({String? deviceId}) =>
      NativeCameraWedge.start(deviceId: deviceId);

  final NativeWedgeStarter _starter;
  final NativeDeviceLister _lister;
  final DateTime Function() _clock;

  NativeWedgeHandle? _handle;
  StreamSubscription<NativeWedgeEvent>? _subscription;
  final _scans = StreamController<CameraWedgeScan>.broadcast();
  final _health = ValueNotifier(CameraWedgeHealth.stopped);
  final _preview = ValueNotifier<CameraWedgePreviewFrame?>(null);
  bool _previewEnabled = false;

  @override
  Stream<CameraWedgeScan> get scans => _scans.stream;

  @override
  ValueListenable<CameraWedgeHealth> get health => _health;

  @override
  ValueListenable<CameraWedgePreviewFrame?> get preview => _preview;

  @override
  bool get supportsPreview => true;

  @override
  Future<List<CameraWedgeDevice>> devices() async {
    final list = await _lister();
    return CameraWedgeDevice.disambiguated([
      for (final device in list.devices)
        CameraWedgeDevice.native(label: device.label, nativeId: device.id),
    ]);
  }

  @override
  Future<void> start({String? deviceId}) async {
    if (_handle != null) return;
    _health.value = const CameraWedgeHealth(state: CameraWedgeState.starting);
    final handle = _starter(deviceId: deviceId);
    _handle = handle;
    _subscription = handle.events.listen(_onEvent);
    if (_previewEnabled) _applyPreview(handle);
  }

  void _onEvent(NativeWedgeEvent event) {
    switch (event) {
      case NativeWedgeStatus():
        _health.value = _healthFrom(event, _health.value);
      case NativeWedgeScan():
        final scan = CameraWedgeScan(
          value: event.text,
          symbology: event.symbology,
          confirmations: event.confirmations,
        );
        if (!_scans.isClosed) _scans.add(scan);
        _health.value = _health.value.copyWith(
          lastScan: scan,
          lastScanAt: _clock(),
        );
      case NativeWedgeStats():
        _health.value = _health.value.copyWith(
          stats: CameraWedgeStats(
            captureFps: event.captureFps,
            framesCaptured: event.framesCaptured,
            framesDecoded: event.framesDecoded,
            decodeMilliseconds: event.decodeMilliseconds,
            scans: event.scans,
            rejectedDisagreements: event.rejectedDisagreements,
            suppressedRereads: event.suppressedRereads,
            active: event.active,
          ),
        );
      case NativeWedgePreview():
        if (_previewEnabled) {
          _preview.value = CameraWedgePreviewFrame(
            width: event.width,
            height: event.height,
            luma: event.luma,
          );
        }
    }
  }

  CameraWedgeHealth _healthFrom(
    NativeWedgeStatus status,
    CameraWedgeHealth previous,
  ) {
    final running = status.state == NativeWedgeState.running;
    return CameraWedgeHealth(
      state: switch (status.state) {
        NativeWedgeState.starting => CameraWedgeState.starting,
        NativeWedgeState.running => CameraWedgeState.running,
        NativeWedgeState.recovering => CameraWedgeState.recovering,
        NativeWedgeState.stopped => CameraWedgeState.stopped,
      },
      fault: _faultFrom(status.error),
      detail: status.message,
      // A camera that just failed still has a name worth showing.
      deviceLabel: status.deviceLabel.isNotEmpty
          ? status.deviceLabel
          : previous.deviceLabel,
      width: status.width,
      height: status.height,
      fps: status.fps,
      pixelFormat: status.pixelFormat,
      substitutedDevice: status.substituted,
      retryIn: status.retryIn,
      // Counters from a camera that is no longer running would be a lie.
      stats: running ? previous.stats : null,
      lastScan: previous.lastScan,
      lastScanAt: previous.lastScanAt,
    );
  }

  static CameraWedgeFault _faultFrom(NativeWedgeError error) => switch (error) {
    NativeWedgeError.none => CameraWedgeFault.none,
    NativeWedgeError.noCamera => CameraWedgeFault.noCamera,
    NativeWedgeError.deviceNotFound => CameraWedgeFault.deviceNotFound,
    NativeWedgeError.accessDenied => CameraWedgeFault.accessDenied,
    NativeWedgeError.inUse => CameraWedgeFault.inUse,
    NativeWedgeError.deviceLost => CameraWedgeFault.deviceLost,
    NativeWedgeError.noUsableFormat => CameraWedgeFault.noUsableFormat,
    NativeWedgeError.stalled => CameraWedgeFault.stalled,
    NativeWedgeError.platform => CameraWedgeFault.platform,
    NativeWedgeError.unsupported => CameraWedgeFault.unsupported,
  };

  @override
  void setPreviewEnabled(bool enabled) {
    if (_previewEnabled == enabled) return;
    _previewEnabled = enabled;
    final handle = _handle;
    if (handle != null) _applyPreview(handle);
    if (!enabled) _preview.value = null;
  }

  void _applyPreview(NativeWedgeHandle handle) {
    handle.setPreview(
      maxEdge: _previewEnabled ? previewMaxEdge : 0,
      interval: previewInterval,
    );
  }

  @override
  Future<void> stop() async {
    final handle = _handle;
    _handle = null;
    // Completes once the native side has let go of the camera, so a restart
    // straight after (a changed camera, the switch flipped off and on) finds
    // it free.
    await handle?.stop();
    await _subscription?.cancel();
    _subscription = null;
    _preview.value = null;
    _health.value = CameraWedgeHealth.stopped.copyWith(
      lastScan: _health.value.lastScan,
      lastScanAt: _health.value.lastScanAt,
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _scans.close();
    _health.dispose();
    _preview.dispose();
  }
}
