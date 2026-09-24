import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scanning_support.dart';
import 'camera_wedge_health.dart';
import 'camera_wedge_policy.dart';
import 'camera_wedge_source.dart';

/// A camera wedge on top of `mobile_scanner` — Android, iOS, macOS and web.
///
/// The platform's own detector does the decoding (ML Kit, Apple Vision, ZXing
/// on the web), so this class never touches a pixel: it turns each frame's
/// detections into readings and lets [CameraWedgePolicy] decide what a till
/// may believe, before anything leaves the source.
class MobileScannerWedgeSource implements CameraWedgeSource {
  MobileScannerWedgeSource({CameraWedgePolicy? policy})
    : _policy = policy ?? CameraWedgePolicy();

  final CameraWedgePolicy _policy;
  MobileScannerController? _controller;
  StreamSubscription<BarcodeCapture>? _subscription;
  final _scans = StreamController<CameraWedgeScan>.broadcast();
  final _health = ValueNotifier(CameraWedgeHealth.stopped);
  final _preview = ValueNotifier<CameraWedgePreviewFrame?>(null);

  /// Exposed so a preview widget can render the same running camera rather
  /// than opening a second one — two `MobileScannerController`s fighting over
  /// one device is a black preview on some platforms and a crash on others.
  MobileScannerController? get controller => _controller;

  @override
  Stream<CameraWedgeScan> get scans => _scans.stream;

  @override
  ValueListenable<CameraWedgeHealth> get health => _health;

  @override
  ValueListenable<CameraWedgePreviewFrame?> get preview => _preview;

  @override
  bool get supportsPreview => false;

  @override
  Future<List<CameraWedgeDevice>> devices() async {
    // mobile_scanner addresses cameras by facing, not by id: there is no
    // enumeration in its API. A shop with two USB cameras picks at the OS
    // level. Reported honestly as a single choice rather than faked.
    if (!cameraScanningSupported) return const [];
    return const [CameraWedgeDevice(id: 'default', label: 'default')];
  }

  @override
  Future<void> start({String? deviceId}) async {
    if (!cameraScanningSupported || _controller != null) return;
    _policy.reset();
    _health.value = const CameraWedgeHealth(state: CameraWedgeState.starting);
    final controller = MobileScannerController(
      // NOT noDuplicates, which is the default the in-app scanner sheet uses
      // and exactly wrong here: the policy reaches confidence by seeing the
      // SAME value from several frames, so a controller that hides repeats
      // would make every 1-D barcode unreadable while looking like it worked.
      detectionSpeed: DetectionSpeed.unrestricted,
      formats: const [],
      facing: CameraFacing.back,
    );
    _controller = controller;
    _subscription = controller.barcodes.listen(
      _handle,
      // A camera unplugged mid-shift must not take the till down with it.
      onError: (Object error) => _health.value = CameraWedgeHealth(
        state: CameraWedgeState.recovering,
        fault: CameraWedgeFault.platform,
        detail: '$error',
      ),
    );
    try {
      await controller.start();
      _health.value = const CameraWedgeHealth(state: CameraWedgeState.running);
    } on Object catch (error) {
      await stop();
      _health.value = CameraWedgeHealth(
        state: CameraWedgeState.stopped,
        fault:
            error is MobileScannerException &&
                error.errorCode == MobileScannerErrorCode.permissionDenied
            ? CameraWedgeFault.accessDenied
            : CameraWedgeFault.platform,
        detail: '$error',
      );
      rethrow;
    }
  }

  void _handle(BarcodeCapture capture) {
    final readings = [
      for (final barcode in capture.barcodes)
        if (barcode.rawValue case final value? when value.trim().isNotEmpty)
          CameraWedgeReading(value: value, symbology: barcode.format.name),
    ];
    final scan = _policy.offerAll(readings);
    if (scan == null || _scans.isClosed) return;
    _scans.add(scan);
    _health.value = _health.value.copyWith(
      lastScan: scan,
      lastScanAt: DateTime.now(),
    );
  }

  @override
  void setPreviewEnabled(bool enabled) {
    // The OS decoder never hands pixels over; a preview here would be a second
    // camera widget, which is what `controller` is exposed for instead.
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      await controller.dispose();
    }
    _policy.reset();
    _health.value = CameraWedgeHealth.stopped;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _scans.close();
    _health.dispose();
    _preview.dispose();
  }
}
