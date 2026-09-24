import 'dart:async';

import 'package:flutter/foundation.dart';

import '../camera_scanning_support.dart';
import 'camera_wedge_health.dart';
import 'camera_wedge_policy.dart';
import 'camera_wedge_source.dart';
import 'mobile_scanner_wedge_source.dart';
import 'native_wedge_source.dart';

/// One camera acting as a barcode wedge for this till.
///
/// Owns a [CameraWedgeSource] and publishes the scans it confirms. From a
/// screen's point of view this is exactly the counter scanner: a stream of
/// strings, same handler, same gating — the shape `CompanionScanListener`
/// already established for a paired phone.
///
/// It notifies when the camera's [health] changes (settings, the F8 preview
/// panel), never per scan: the point of the feature is that nobody looks at
/// the camera. Preview frames have their own listenable, [preview], and flow
/// only while somebody holds [acquirePreview].
class CameraWedgeController extends ChangeNotifier {
  CameraWedgeController({CameraWedgeSource? source})
    : _source = source ?? _sourceForThisPlatform() {
    _source?.health.addListener(notifyListeners);
  }

  final CameraWedgeSource? _source;
  bool _isRunning = false;
  Object? _startError;
  int _previewHolders = 0;
  bool _disposed = false;

  static final ValueNotifier<CameraWedgePreviewFrame?> _noPreview =
      ValueNotifier(null);

  /// Whether this platform can run a camera wedge at all, and how.
  ///
  /// `mobile_scanner` where it exists; the native wedge where its library
  /// loads (Windows, and Linux once it has a capture backend); otherwise
  /// nothing, and the setting says so instead of offering a dead switch.
  static CameraWedgeBackend get backend {
    if (cameraScanningSupported) return CameraWedgeBackend.platformScanner;
    if (nativeCameraWedgeAvailable) return CameraWedgeBackend.native;
    return CameraWedgeBackend.none;
  }

  static CameraWedgeSource? _sourceForThisPlatform() => switch (backend) {
    CameraWedgeBackend.platformScanner => MobileScannerWedgeSource(),
    CameraWedgeBackend.native => createNativeWedgeSource(),
    CameraWedgeBackend.none => null,
  };

  /// Confirmed scans, in the order a till should act on them.
  Stream<CameraWedgeScan> get scans => _source?.scans ?? const Stream.empty();

  bool get isRunning => _isRunning;

  /// What the camera is doing, including why it is not reading — a refused
  /// permission reads as a refused permission rather than as a feature that
  /// does nothing.
  CameraWedgeHealth get health {
    final error = _startError;
    if (error != null) {
      return CameraWedgeHealth(
        state: CameraWedgeState.stopped,
        fault: _source == null
            ? CameraWedgeFault.unsupported
            : CameraWedgeFault.platform,
        detail: '$error',
      );
    }
    return _source?.health.value ?? CameraWedgeHealth.stopped;
  }

  /// The newest frame while a preview is held, for aiming the camera.
  ValueListenable<CameraWedgePreviewFrame?> get preview =>
      _source?.preview ?? _noPreview;

  bool get supportsPreview => _source?.supportsPreview ?? false;

  Future<List<CameraWedgeDevice>> devices() async =>
      await _source?.devices() ?? const [];

  Future<void> start({String? deviceId}) async {
    final source = _source;
    if (source == null || _isRunning) return;
    _startError = null;
    try {
      await source.start(deviceId: deviceId);
      _isRunning = true;
    } catch (error) {
      // The library would not load or refused to start. The till keeps
      // trading; the wedge simply is not there, and settings says why.
      _startError = error;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    await _source?.stop();
    _isRunning = false;
    if (!_disposed) notifyListeners();
  }

  /// Start preview frames for as long as the caller holds them. Counted, so
  /// the settings page and the F8 panel can both be open without one turning
  /// the other's frames off.
  void acquirePreview() {
    _previewHolders += 1;
    if (_previewHolders == 1) _source?.setPreviewEnabled(true);
  }

  void releasePreview() {
    if (_previewHolders == 0) return;
    _previewHolders -= 1;
    if (_previewHolders == 0 && !_disposed) _source?.setPreviewEnabled(false);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _source?.health.removeListener(notifyListeners);
    super.dispose();
    await _source?.dispose();
  }
}
