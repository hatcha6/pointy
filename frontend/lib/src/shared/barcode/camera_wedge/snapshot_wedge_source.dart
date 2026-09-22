import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

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
/// So this takes stills in a loop instead. That is slower than the ~80
/// attempts/second the same decoder manages off a live stream, and the
/// difference lands exactly where it can be afforded: a 2-D code is
/// Reed-Solomon protected and believed on one good read, so a payment
/// terminal's receipt QR — the thing the counter wedge cannot read at
/// all — resolves on the first still that comes out sharp.
///
/// **It reads 2-D only.** `zxing2` is pure Dart, which is what keeps this path
/// free of any native build that could break a Windows release, and it ships
/// no 1-D readers. A till here still scans EAN-13 the way it always has, with
/// the wedge on the counter. Swapping in a multi-format decoder later is a
/// change to [_decode] and nothing else.
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
        // Enough pixels across a QR at counter height without paying for a
        // 4K still on every attempt.
        resolutionPreset: ResolutionPreset.high,
        enableAudio: false,
      ),
    );
    await _platform.initializeCamera(cameraId);
    _cameraId = cameraId;
    _running = true;
    _loop = _pump();
  }

  Future<void> _pump() async {
    while (_running) {
      final cameraId = _cameraId;
      if (cameraId == null) break;
      try {
        final file = await _platform.takePicture(cameraId);
        final bytes = await file.readAsBytes();
        // Decoding a full-resolution still on the UI isolate would jank the
        // till on every attempt, and the till is what the cashier is using.
        final found = await compute(_decode, bytes);
        if (found != null && _running) {
          _readings.add(
            CameraWedgeReading(value: found, symbology: 'QRCode'),
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

/// Runs on a background isolate — must be a top-level function.
String? _decode(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final source = RGBLuminanceSource(
      decoded.width,
      decoded.height,
      decoded
          .convert(numChannels: 4)
          .getBytes(order: img.ChannelOrder.abgr)
          .buffer
          .asInt32List(),
    );
    final result = QRCodeReader().decode(
      BinaryBitmap(HybridBinarizer(source)),
    );
    final text = result.text.trim();
    return text.isEmpty ? null : text;
  } on NotFoundException {
    // The overwhelmingly common case: a counter with nothing on it.
    return null;
  } catch (_) {
    return null;
  }
}
