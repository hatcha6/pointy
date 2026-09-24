import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_camera_wedge/pointy_camera_wedge.dart';

/// The message layouts of src/include/pointy_camera_wedge.h, as the native
/// side posts them (api/dart_port_sink.cpp builds exactly these Lists).
void main() {
  test('a status reports state, fault, stream and retry', () {
    final event = NativeWedgeEvent.parse([
      1, 3, 3, 'opening the camera failed (0x80070005)', r'\\?\usb#vid_0c45',
      'HUE HD Pro camera', 1280, 720, 30000, 'MJPG>NV12', 1, 5000, //
    ]);

    expect(event, isA<NativeWedgeStatus>());
    final status = event! as NativeWedgeStatus;
    expect(status.state, NativeWedgeState.recovering);
    expect(status.error, NativeWedgeError.accessDenied);
    expect(status.deviceLabel, 'HUE HD Pro camera');
    expect(status.width, 1280);
    expect(status.fps, 30.0);
    expect(status.pixelFormat, 'MJPG>NV12');
    expect(status.substituted, isTrue);
    expect(status.retryIn, const Duration(seconds: 5));
  });

  test('a scan carries the value the native policy confirmed', () {
    final event = NativeWedgeEvent.parse([2, '3600523434725', 'EAN13', 2]);

    final scan = event! as NativeWedgeScan;
    expect(scan.text, '3600523434725');
    expect(scan.symbology, 'EAN13');
    expect(scan.confirmations, 2);
  });

  test('stats scale their fixed-point fields back', () {
    final stats =
        NativeWedgeEvent.parse([3, 900, 150, 12, 1, 2, 40, 29970, 7250, 1])!
            as NativeWedgeStats;

    expect(stats.framesCaptured, 900);
    expect(stats.framesDecoded, 150);
    expect(stats.rejectedDisagreements, 2);
    expect(stats.captureFps, closeTo(29.97, 1e-9));
    expect(stats.decodeMilliseconds, closeTo(7.25, 1e-9));
    expect(stats.active, isTrue);
  });

  test('a preview is refused when its pixels do not match its size', () {
    final good = NativeWedgeEvent.parse([4, 4, 2, Uint8List(8)]);
    final bad = NativeWedgeEvent.parse([4, 4, 2, Uint8List(7)]);

    expect(good, isA<NativeWedgePreview>());
    expect(bad, isNull);
  });

  test('probes, unknown kinds and malformed lists are ignored', () {
    // A bare integer is the library checking the port is still open.
    expect(NativeWedgeEvent.parse(0), isNull);
    expect(NativeWedgeEvent.parse(<Object?>[]), isNull);
    expect(NativeWedgeEvent.parse([99, 'from a newer library']), isNull);
    expect(NativeWedgeEvent.parse([2, 'missing fields']), isNull);
    expect(NativeWedgeEvent.parse([1, 'not a number']), isNull);
  });

  test('an unknown fault code reads as a platform fault, not as none', () {
    expect(NativeWedgeError.fromCode(42), NativeWedgeError.platform);
    expect(NativeWedgeError.fromCode(0), NativeWedgeError.none);
    expect(NativeWedgeState.fromCode(4), NativeWedgeState.stopped);
  });

  test('a device list pairs ids with labels', () {
    final list = NativeDeviceList.parse([
      5,
      0,
      '',
      [r'\\?\usb#a', 'Integrated Webcam', r'\\?\usb#b', 'HUE HD Pro'],
    ])!;

    expect(list.error, NativeWedgeError.none);
    expect(
        list.devices.map((d) => d.label), ['Integrated Webcam', 'HUE HD Pro']);
    expect(list.devices.first.id, r'\\?\usb#a');
    expect(NativeDeviceList.parse([2, 'x', 'EAN13', 1]), isNull);
  });
}
