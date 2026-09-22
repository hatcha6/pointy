import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_zxing/flutter_zxing.dart' as zxing;

import 'camera_wedge_policy.dart';
import 'camera_wedge_source.dart';

/// A camera wedge for the platforms with no live frame stream — which is the
/// one that matters, because the tills are Windows.
///
/// `camera_windows` is the Flutter team's own implementation and the only way
/// to reach a UVC camera there, but it has no image stream:
///
///     throw UnimplementedError('Streaming is not currently supported on Windows')
///     — camera_windows/lib/camera_windows.dart
///
/// So this takes stills in a loop instead, and hands each one to **zxing-cpp**
/// through `flutter_zxing`. That is the same engine the backend already runs
/// (`apps/companion/decoding.py`) and the same one `tools/camera-wedge-lab`
/// measured, so everything the lab found — the 12% checksum-passing misread
/// rate that [CameraWedgePolicy] exists to defeat, the rotation behaviour —
/// transfers exactly rather than approximately. C++ is what makes that
/// possible: one decoder, five platforms, sources vendored in the package so
/// nothing is fetched at build time.
///
/// Stills are slower than the ~80 attempts/second the same decoder manages off
/// a live stream, and the difference lands where it can be afforded: a 2-D
/// code is Reed-Solomon protected and believed on one good read, so a payment
/// terminal's receipt QR — the thing the counter wedge cannot read at all —
/// resolves on the first still that comes out sharp. A 1-D barcode needs two
/// agreeing looks and is correspondingly slower here, which is the trade a
/// shop accepts for not buying a scanner.
class SnapshotWedgeSource implements CameraWedgeSource {
  SnapshotWedgeSource({
    this.interval = const Duration(milliseconds: 250),
    CameraPlatform? platform,
  }) : _platform = platform ?? CameraPlatform.instance;

  /// How long to wait between stills. Not a frame rate: `takePicture` on
  /// Windows costs a few hundred milliseconds of its own, so this is the
  /// breather on top, keeping a till's CPU for the till.
  final Duration interval;

  final CameraPlatform _platform;
  final _readings = StreamController<CameraWedgeReading>.broadcast();

  int? _cameraId;
  bool _running = false;
  Future<void>? _loop;

  @override
  Stream<CameraWedgeReading> get readings => _readings.stream;

  @override
  Future<List<CameraWedgeDevice>> devices() async {
    try {
      final cameras = await _platform.availableCameras();
      return [
        for (final camera in cameras)
          CameraWedgeDevice(id: camera.name, label: camera.name),
      ];
    } catch (_) {
      // A machine with no camera is not an error state; it is a machine with
      // no camera, and the setting simply offers nothing to pick.
      return const [];
    }
  }

  @override
  Future<void> start({String? deviceId}) async {
    if (_running) return;
    final cameras = await _platform.availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No camera on this machine.');
    }
    final chosen = cameras.firstWhere(
      (camera) => camera.name == deviceId,
      // A shop that has not picked, or that unplugged the one it picked and
      // put back a different one, gets the first camera rather than nothing.
      orElse: () => cameras.first,
    );
    final cameraId = await _platform.createCameraWithSettings(
      chosen,
      const MediaSettings(
        // Enough pixels across a barcode at counter height without paying for
        // a 4K still on every attempt.
        resolutionPreset: ResolutionPreset.high,
        enableAudio: false,
      ),
    );
    await _platform.initializeCamera(cameraId);
    _cameraId = cameraId;
    _running = true;
    _loop = _pump();
  }

  /// What the lab learned, as decoder settings.
  ///
  /// `tryRotate` and `tryHarder` are both on because a cashier puts an item
  /// down however it lands: with `tryHarder` off, a tilted EAN-13 sat unread
  /// for 14.7 seconds — 59 consecutive failed attempts while sharp and
  /// still — because the linear scanner sweeps a few rows along one axis and
  /// nothing crossed the bars. It costs a few milliseconds against a budget
  /// measured in hundreds.
  static zxing.DecodeParams get _params => zxing.DecodeParams(
        format: zxing.Format.any,
        tryHarder: true,
        tryRotate: true,
        tryInverted: true,
        maxNumberOfSymbols: 1,
      );

  Future<void> _pump() async {
    while (_running) {
      final cameraId = _cameraId;
      if (cameraId == null) break;
      try {
        final file = await _platform.takePicture(cameraId);
        final code = await zxing.zx.readBarcodeImagePathString(
          file.path,
          _params,
        );
        final text = code.text?.trim();
        if (code.isValid && text != null && text.isNotEmpty && _running) {
          _readings.add(
            CameraWedgeReading(
              value: text,
              symbology: _symbologyName(code.format),
            ),
          );
        }
      } catch (_) {
        // A still that failed is a scan that did not happen. A camera
        // unplugged mid-shift must not take the till down with it, so the
        // loop simply keeps asking until stop() says otherwise.
      }
      if (!_running) break;
      await Future<void>.delayed(interval);
    }
  }

  /// zxing's format is a bitmask; [CameraWedgeSymbology] speaks names, because
  /// that is what every other source reports and the policy must judge them
  /// all by the same rule. An unmapped format falls through to the least
  /// trusted class, which costs a slower scan rather than a wrong one.
  static String _symbologyName(int? format) => switch (format) {
        zxing.Format.qrCode => 'QRCode',
        zxing.Format.microQRCode => 'MicroQRCode',
        zxing.Format.dataMatrix => 'DataMatrix',
        zxing.Format.aztec => 'Aztec',
        zxing.Format.pdf417 => 'PDF417',
        zxing.Format.ean13 => 'EAN13',
        zxing.Format.ean8 => 'EAN8',
        zxing.Format.upca => 'UPCA',
        zxing.Format.upce => 'UPCE',
        zxing.Format.code128 => 'Code128',
        zxing.Format.code93 => 'Code93',
        zxing.Format.code39 => 'Code39',
        zxing.Format.itf => 'ITF',
        zxing.Format.codabar => 'Codabar',
        _ => 'unknown',
      };

  @override
  Future<void> stop() async {
    _running = false;
    await _loop;
    _loop = null;
    final cameraId = _cameraId;
    _cameraId = null;
    if (cameraId != null) {
      try {
        await _platform.dispose(cameraId);
      } catch (_) {
        // Already gone. Releasing a camera twice is not worth a crash.
      }
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _readings.close();
  }
}
