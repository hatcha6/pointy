import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_camera_wedge/pointy_camera_wedge.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_health.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_source.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/native_wedge_source_io.dart';

/// The native library, as the app sees it: a stream of events. The real one
/// is exercised through FFI in packages/pointy_camera_wedge/test.
class _FakeHandle implements NativeWedgeHandle {
  final _events = StreamController<NativeWedgeEvent>.broadcast(sync: true);
  final previewRequests = <int>[];
  bool stopped = false;

  void emit(NativeWedgeEvent event) => _events.add(event);

  @override
  Stream<NativeWedgeEvent> get events => _events.stream;

  @override
  void setPreview({required int maxEdge, Duration interval = Duration.zero}) =>
      previewRequests.add(maxEdge);

  @override
  Future<void> stop() async {
    stopped = true;
    emit(const NativeWedgeStatus(state: NativeWedgeState.stopped));
    await _events.close();
  }
}

void main() {
  late _FakeHandle handle;
  late List<String?> startedWith;
  late NativeWedgeSource source;

  setUp(() {
    handle = _FakeHandle();
    startedWith = [];
    source = NativeWedgeSource(
      starter: ({String? deviceId}) {
        startedWith.add(deviceId);
        return handle;
      },
      lister: () async => const NativeDeviceList(
        devices: [
          NativeCameraDevice(id: r'\\?\usb#a', label: 'USB Camera'),
          NativeCameraDevice(id: r'\\?\usb#b', label: 'USB Camera'),
          NativeCameraDevice(id: r'\\?\usb#c', label: 'HUE HD Pro camera'),
        ],
      ),
      clock: () => DateTime(2026, 9, 24, 14),
    );
  });

  test('a native scan arrives as a confirmed scan, unchanged', () async {
    final scans = <CameraWedgeScan>[];
    source.scans.listen(scans.add);
    await source.start(deviceId: 'HUE HD Pro camera <x>');

    handle.emit(
      const NativeWedgeScan(
        text: '3600523434725',
        symbology: 'EAN13',
        confirmations: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(startedWith, ['HUE HD Pro camera <x>']);
    expect(scans.single.value, '3600523434725');
    expect(scans.single.confirmations, 2);
    expect(source.health.value.lastScan?.value, '3600523434725');
    expect(source.health.value.lastScanAt, DateTime(2026, 9, 24, 14));
  });

  test(
    'a status becomes health: state, fault, what the camera sends',
    () async {
      await source.start();

      handle.emit(
        const NativeWedgeStatus(
          state: NativeWedgeState.running,
          deviceLabel: 'HUE HD Pro camera',
          width: 1280,
          height: 720,
          fps: 30,
          pixelFormat: 'MJPG>NV12',
        ),
      );
      expect(source.health.value.state, CameraWedgeState.running);
      expect(source.health.value.width, 1280);
      expect(source.health.value.pixelFormat, 'MJPG>NV12');

      handle.emit(
        const NativeWedgeStatus(
          state: NativeWedgeState.recovering,
          error: NativeWedgeError.accessDenied,
          message: 'opening the camera failed (0x80070005)',
          retryIn: Duration(seconds: 5),
        ),
      );
      final health = source.health.value;
      expect(health.state, CameraWedgeState.recovering);
      expect(health.fault, CameraWedgeFault.accessDenied);
      expect(health.retryIn, const Duration(seconds: 5));
      // The camera that just failed keeps its name on screen.
      expect(health.deviceLabel, 'HUE HD Pro camera');
    },
  );

  test('stats from a camera that stopped running are not kept', () async {
    await source.start();
    handle
      ..emit(const NativeWedgeStatus(state: NativeWedgeState.running))
      ..emit(const NativeWedgeStats(captureFps: 29.97, framesDecoded: 12));
    expect(source.health.value.stats?.captureFps, 29.97);

    handle.emit(
      const NativeWedgeStatus(
        state: NativeWedgeState.recovering,
        error: NativeWedgeError.deviceLost,
      ),
    );

    expect(source.health.value.stats, isNull);
  });

  test('preview frames flow only while asked for', () async {
    await source.start();
    final frame = NativeWedgePreview(
      width: 2,
      height: 1,
      luma: Uint8List.fromList([0, 255]),
    );

    handle.emit(frame);
    expect(source.preview.value, isNull);

    source.setPreviewEnabled(true);
    handle.emit(frame);
    expect(source.preview.value?.width, 2);

    source.setPreviewEnabled(false);
    expect(source.preview.value, isNull);
    expect(handle.previewRequests, [NativeWedgeSource.previewMaxEdge, 0]);
  });

  test('a preview asked for before start is applied on start', () async {
    source.setPreviewEnabled(true);
    await source.start();

    expect(handle.previewRequests, [NativeWedgeSource.previewMaxEdge]);
  });

  test('stop waits for the native side and resets to stopped', () async {
    await source.start();
    handle.emit(const NativeWedgeStatus(state: NativeWedgeState.running));

    await source.stop();

    expect(handle.stopped, isTrue);
    expect(source.health.value.state, CameraWedgeState.stopped);
  });

  test(
    'devices keep camera_windows ids so an old pick still matches',
    () async {
      final devices = await source.devices();

      expect(devices.map((d) => d.id), [
        r'USB Camera <\\?\usb#a>',
        r'USB Camera <\\?\usb#b>',
        r'HUE HD Pro camera <\\?\usb#c>',
      ]);
      // Two identical webcams are told apart rather than shown twice.
      expect(devices.map((d) => d.label), [
        'USB Camera (1)',
        'USB Camera (2)',
        'HUE HD Pro camera',
      ]);
      expect(
        CameraWedgeDevice.displayNameFrom(devices.last.id),
        'HUE HD Pro camera',
      );
    },
  );

  group('the controller over a source', () {
    test('preview frames are counted, not toggled', () async {
      final controller = CameraWedgeController(source: source);
      await controller.start();

      controller.acquirePreview(); // settings open
      controller.acquirePreview(); // and the F8 panel
      controller.releasePreview(); // F8 closed: settings still watching
      expect(handle.previewRequests, [NativeWedgeSource.previewMaxEdge]);

      controller.releasePreview();
      expect(handle.previewRequests, [NativeWedgeSource.previewMaxEdge, 0]);
      await controller.dispose();
    });

    test('a library that will not start is a fault, not a crash', () async {
      final controller = CameraWedgeController(
        source: NativeWedgeSource(
          starter: ({String? deviceId}) =>
              throw UnsupportedError('could not load the camera library'),
          lister: () async => const NativeDeviceList(devices: []),
        ),
      );

      await controller.start();

      expect(controller.isRunning, isFalse);
      expect(controller.health.fault, CameraWedgeFault.platform);
      expect(controller.health.detail, contains('camera library'));
      await controller.dispose();
    });

    test('health changes reach listeners', () async {
      final controller = CameraWedgeController(source: source);
      var notified = 0;
      controller.addListener(() => notified += 1);
      await controller.start();

      handle.emit(const NativeWedgeStatus(state: NativeWedgeState.running));

      expect(controller.health.isRunning, isTrue);
      expect(notified, greaterThan(0));
      await controller.dispose();
    });
  });
}
