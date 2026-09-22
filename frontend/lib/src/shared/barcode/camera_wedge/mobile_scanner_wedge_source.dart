import 'dart:async';

import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scanning_support.dart';
import 'camera_wedge_policy.dart';
import 'camera_wedge_source.dart';

/// A camera wedge on top of `mobile_scanner` — Android, iOS, macOS and web.
///
/// The platform's own detector does the decoding (ML Kit, Apple Vision, ZXing
/// on the web), so this class never touches a pixel: it turns a stream of
/// detections into [CameraWedgeReading]s and lets [CameraWedgePolicy] decide
/// what a till may believe.
class MobileScannerWedgeSource implements CameraWedgeSource {
  MobileScannerWedgeSource();

  MobileScannerController? _controller;
  StreamSubscription<BarcodeCapture>? _subscription;
  final _readings = StreamController<CameraWedgeReading>.broadcast();

  /// Exposed so a preview widget can render the same running camera rather
  /// than opening a second one — two `MobileScannerController`s fighting over
  /// one device is a black preview on some platforms and a crash on others.
  MobileScannerController? get controller => _controller;

  @override
  Stream<CameraWedgeReading> get readings => _readings.stream;

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
    if (!cameraScanningSupported) return;
    if (_controller != null) return;
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
      onError: (Object _) {},
    );
    await controller.start();
  }

  void _handle(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      _readings.add(
        CameraWedgeReading(value: value, symbology: barcode.format.name),
      );
    }
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
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _readings.close();
  }
}
