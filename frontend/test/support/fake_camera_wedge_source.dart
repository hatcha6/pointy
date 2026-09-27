import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_health.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_source.dart';

/// A counter camera under the test's control. It confirms what it "sees" with
/// the real policy before anything leaves it, the way both real sources do
/// (the native one in C++, mobile_scanner's in Dart), so a test sees exactly
/// the scans a till would.
class FakeCameraWedgeSource implements CameraWedgeSource {
  final policy = CameraWedgePolicy();
  final _scans = StreamController<CameraWedgeScan>.broadcast();
  final _health = ValueNotifier(CameraWedgeHealth.stopped);
  final _preview = ValueNotifier<CameraWedgePreviewFrame?>(null);
  bool started = false;

  /// One look at [value]. A QR is believed on one look; a retail 1-D code
  /// needs a second agreeing one before it becomes a scan.
  void see(String value, {String symbology = 'QRCode'}) {
    final scan = policy.offer(
      CameraWedgeReading(value: value, symbology: symbology),
    );
    if (scan != null) _scans.add(scan);
  }

  @override
  Stream<CameraWedgeScan> get scans => _scans.stream;

  @override
  ValueListenable<CameraWedgeHealth> get health => _health;

  @override
  ValueListenable<CameraWedgePreviewFrame?> get preview => _preview;

  @override
  bool get supportsPreview => false;

  @override
  void setPreviewEnabled(bool enabled) {}

  @override
  Future<List<CameraWedgeDevice>> devices() async => const [
    CameraWedgeDevice(id: 'x', label: 'x'),
  ];

  @override
  Future<void> start({String? deviceId}) async => started = true;

  @override
  Future<void> stop() async => started = false;

  @override
  Future<void> dispose() async => _scans.close();
}
