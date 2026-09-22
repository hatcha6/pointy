import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_source.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/snapshot_decoder.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/snapshot_wedge_source.dart';

void main() {
  group('camera names as a shop reads them', () {
    // The two cameras on the till that reported this, exactly as
    // camera_windows spelled them.
    const integrated =
        r'Integrated Webcam <\\?\usb#vid_1bcf&pid_2b94&mi_00#6&316f151d&0&0000'
        r'#{e5323777-f976-4f5b-9b55-b94699c46e44}\global>';
    const hue =
        r'HUE HD Pro camera <\\?\usb#vid_0c45&pid_636b&mi_00#6&1b1fbcda&0&0000'
        r'#{e5323777-f976-4f5b-9b55-b94699c46e44}\global>';

    test('shows the display name and keeps the id the platform needs', () {
      final device = CameraWedgeDevice.fromPlatformName(hue);

      expect(device.label, 'HUE HD Pro camera');
      // The id must survive whole: camera_windows parses the display name and
      // the device id back out of this exact string when it opens the camera.
      expect(device.id, hue);
    });

    test('leaves a name that is not in the windows shape alone', () {
      for (final name in const [
        'FaceTime HD Camera',
        'default',
        'Logitech C920 <incomplete',
        '<only-an-id>',
      ]) {
        expect(CameraWedgeDevice.displayNameFrom(name), name);
      }
    });

    test('numbers two cameras that report the same name', () {
      final devices = CameraWedgeDevice.disambiguated([
        const CameraWedgeDevice(id: 'a', label: 'USB Camera'),
        const CameraWedgeDevice(id: 'b', label: 'USB Camera'),
        const CameraWedgeDevice(id: 'c', label: 'Integrated Webcam'),
      ]);

      expect(devices.map((device) => device.label), [
        'USB Camera (1)',
        'USB Camera (2)',
        'Integrated Webcam',
      ]);
      // Numbering is cosmetic; the ids are what the pick is stored as.
      expect(devices.map((device) => device.id), ['a', 'b', 'c']);
    });

    test('offers both cameras by name', () async {
      final source = SnapshotWedgeSource(
        platform: _FakeCameraPlatform(cameras: const [integrated, hue]),
        decoder: _neverReads,
      );

      expect(await source.devices(), const [
        CameraWedgeDevice(id: integrated, label: 'Integrated Webcam'),
        CameraWedgeDevice(id: hue, label: 'HUE HD Pro camera'),
      ]);
    });
  });

  group('running the camera', () {
    test('pauses the preview nobody looks at', () async {
      final platform = _FakeCameraPlatform(cameras: const ['A <id-a>']);
      final source = SnapshotWedgeSource(
        platform: platform,
        decoder: _neverReads,
      );

      await source.start();
      await source.stop();

      // initializeCamera starts a preview unconditionally; left running it
      // converts, copies and publishes every frame at the engine for a texture
      // no widget paints.
      expect(platform.pausedPreviews, [platform.lastCameraId]);
    });

    test('opens the camera the shop picked, by its full id', () async {
      final platform = _FakeCameraPlatform(
        cameras: const ['A <id-a>', 'B <id-b>'],
      );
      final source = SnapshotWedgeSource(
        platform: platform,
        decoder: _neverReads,
      );

      await source.start(deviceId: 'B <id-b>');
      await source.stop();

      expect(platform.openedCamera, 'B <id-b>');
      expect(source.substitutedDevice, isFalse);
    });

    test('says so when the picked camera is gone', () async {
      final platform = _FakeCameraPlatform(cameras: const ['A <id-a>']);
      final source = SnapshotWedgeSource(
        platform: platform,
        decoder: _neverReads,
      );

      await source.start(deviceId: 'B <id-b>');
      await source.stop();

      // It keeps trading on whatever is there — but reading off the camera
      // facing the cashier instead of the one on the stand is the feature
      // failing, so it must not be silent.
      expect(platform.openedCamera, 'A <id-a>');
      expect(source.substitutedDevice, isTrue);
    });

    test(
      'settles for an uncapped preview when the capped one is refused',
      () async {
        final platform = _FakeCameraPlatform(
          cameras: const ['A <id-a>'],
          refusePresets: const {ResolutionPreset.high},
        );
        final source = SnapshotWedgeSource(
          platform: platform,
          decoder: _neverReads,
        );

        await source.start();
        await source.stop();

        // A camera with no mode under the cap at 15fps or better fails to open
        // at all, because camera_windows needs a preview media type before it
        // will report success — and the preview is paused a moment later anyway.
        expect(platform.requestedPresets, [
          ResolutionPreset.high,
          ResolutionPreset.max,
        ]);
      },
    );

    test(
      'reports what a still read, in the order the pictures were taken',
      () async {
        final platform = _FakeCameraPlatform(cameras: const ['A <id-a>']);
        final source = SnapshotWedgeSource(
          platform: platform,
          decoder: (path, {required int maxSize}) async {
            // The second still answers first. The policy judges agreement by how
            // far apart two looks at the counter were, so order and timestamps
            // must follow the shutter, not the worker.
            if (path.endsWith('1')) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
            return SnapshotDecode.read(value: 'code-$path', symbology: 'EAN13');
          },
        );

        final readings = <CameraWedgeReading>[];
        final both = Completer<void>();
        final sub = source.readings.listen((reading) {
          readings.add(reading);
          if (readings.length == 2 && !both.isCompleted) both.complete();
        });
        await source.start();
        await both.future.timeout(const Duration(seconds: 5));
        await source.stop();
        await sub.cancel();

        expect(readings[0].value, 'code-still-1');
        expect(readings[1].value, 'code-still-2');
        expect(readings[0].at, isNotNull);
        expect(readings[0].at!.isAfter(readings[1].at!), isFalse);
      },
    );

    test('surfaces a camera that opens and then fails every still', () async {
      final platform = _FakeCameraPlatform(
        cameras: const ['A <id-a>'],
        pictureError: StateError('device busy'),
      );
      final source = SnapshotWedgeSource(
        platform: platform,
        decoder: _neverReads,
      );

      await source.start();
      await platform.afterPictures(2);
      await source.stop();

      // The whole reason this was invisible: the loop used to catch everything
      // and say nothing, so a broken camera and an empty counter looked alike.
      expect(source.lastError, isA<StateError>());
      expect(source.stillsFailed, greaterThan(0));
    });

    test('a still with nothing in it is not a failure', () async {
      final platform = _FakeCameraPlatform(cameras: const ['A <id-a>']);
      final source = SnapshotWedgeSource(
        platform: platform,
        decoder: _neverReads,
      );

      await source.start();
      await platform.afterPictures(2);
      await source.stop();

      expect(source.stillsTaken, greaterThan(0));
      expect(source.stillsFailed, 0);
      expect(source.lastError, isNull);
    });
  });

  group('agreement at the cadence this backend delivers', () {
    // The bug that made the feature useless in a shop: two agreeing looks are
    // required for a retail barcode, and on this backend two looks are about a
    // second apart. Under a window sized for a live stream they could never
    // both count, so no 1-D barcode could EVER be confirmed — while the
    // settings page reported the camera as running.
    CameraWedgeScan? confirm(CameraWedgePolicy policy, Duration apart) {
      final start = DateTime(2026, 9, 22, 12);
      policy.offer(
        CameraWedgeReading(
          value: '3600523434725',
          symbology: 'EAN13',
          at: start,
        ),
      );
      return policy.offer(
        CameraWedgeReading(
          value: '3600523434725',
          symbology: 'EAN13',
          at: start.add(apart),
        ),
      );
    }

    test('a live stream window cannot confirm a snapshot-paced read', () {
      expect(
        confirm(CameraWedgePolicy(), SnapshotWedgeSource.lookInterval),
        isNull,
      );
    });

    test('the snapshot window can', () {
      final policy = CameraWedgePolicy(
        agreementWindow: SnapshotWedgeSource.lookInterval * 3,
      );

      final scan = confirm(policy, SnapshotWedgeSource.lookInterval);

      expect(scan, isNotNull);
      expect(scan!.value, '3600523434725');
      expect(scan.confirmations, 2);
    });

    test('and still refuses two looks that are genuinely far apart', () {
      final policy = CameraWedgePolicy(
        agreementWindow: SnapshotWedgeSource.lookInterval * 3,
      );

      expect(confirm(policy, const Duration(seconds: 10)), isNull);
    });
  });
}

Future<SnapshotDecode> _neverReads(String path, {required int maxSize}) async =>
    const SnapshotDecode.blank();

/// A camera that answers instantly and records what it was asked for.
class _FakeCameraPlatform extends CameraPlatform {
  _FakeCameraPlatform({
    required this.cameras,
    this.pictureError,
    this.refusePresets = const {},
  });

  final List<String> cameras;
  final Object? pictureError;
  final Set<ResolutionPreset> refusePresets;

  final List<ResolutionPreset> requestedPresets = [];
  final List<int> pausedPreviews = [];
  String? openedCamera;
  int lastCameraId = 0;
  int pictures = 0;

  final _pictureTargets = <int, Completer<void>>{};

  /// Completes once [count] pictures have been asked for.
  Future<void> afterPictures(int count) {
    if (pictures >= count) return Future<void>.value();
    return (_pictureTargets[count] ??= Completer<void>()).future;
  }

  @override
  Future<List<CameraDescription>> availableCameras() async => [
    for (final name in cameras)
      CameraDescription(
        name: name,
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 0,
      ),
  ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings? mediaSettings,
  ) async {
    final preset = mediaSettings?.resolutionPreset ?? ResolutionPreset.max;
    requestedPresets.add(preset);
    if (refusePresets.contains(preset)) {
      throw CameraException('camera_error', 'Failed to initialize');
    }
    openedCamera = description.name;
    return lastCameraId = requestedPresets.length;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Future<void> pausePreview(int cameraId) async => pausedPreviews.add(cameraId);

  @override
  Future<XFile> takePicture(int cameraId) async {
    // A real capture is a few hundred milliseconds; enough of a pause here
    // that the loop cannot spin the test machine.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    pictures += 1;
    for (final entry in _pictureTargets.entries.toList()) {
      if (pictures >= entry.key && !entry.value.isCompleted) {
        entry.value.complete();
      }
    }
    final error = pictureError;
    if (error != null) throw error;
    return XFile('still-$pictures');
  }

  @override
  Future<void> dispose(int cameraId) async {}
}
