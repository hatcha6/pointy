import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_camera_wedge/pointy_camera_wedge.dart';

/// The real library through the real FFI boundary: port, message layouts,
/// threads, lifecycle. Needs a build with the synthetic camera (drawn frames),
/// so it runs only when one is pointed at:
///
///   cmake -S src -B build -DPCW_BUILD_TESTS=ON && cmake --build build
///   POINTY_CAMERA_WEDGE_LIBRARY=$PWD/build/libpointy_camera_wedge.dylib \
///     flutter test test/native_camera_wedge_integration_test.dart
///
/// (`make frontend-camera-wedge-test` does both.)
void main() {
  final library = Platform.environment['POINTY_CAMERA_WEDGE_LIBRARY'];
  final skip = library == null || library.isEmpty
      ? 'set POINTY_CAMERA_WEDGE_LIBRARY to a synthetic-backend build'
      : false;

  Future<List<NativeWedgeEvent>> collectUntil(
    NativeCameraWedge wedge,
    bool Function(List<NativeWedgeEvent> seen) done, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final seen = <NativeWedgeEvent>[];
    final finished = Completer<void>();
    final subscription = wedge.events.listen((event) {
      seen.add(event);
      if (!finished.isCompleted && done(seen)) finished.complete();
    });
    try {
      await finished.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
    return seen;
  }

  Future<List<NativeWedgeEvent>> collectFor(
    NativeCameraWedge wedge,
    Duration duration,
  ) async {
    final seen = <NativeWedgeEvent>[];
    final subscription = wedge.events.listen(seen.add);
    await Future<void>.delayed(duration);
    await subscription.cancel();
    return seen;
  }

  test('the library loads and says it can run', () {
    final availability = NativeCameraWedge.availability;
    expect(availability.isAvailable, isTrue, reason: availability.reason);
  }, skip: skip);

  test('cameras are listed on a native thread', () async {
    final list = await NativeCameraWedge.listDevices();

    expect(list.error, NativeWedgeError.none);
    expect(list.devices.map((d) => d.label), contains('Synthetic EAN-13'));
  }, skip: skip);

  test('a barcode under the camera arrives as one confirmed scan', () async {
    final wedge = NativeCameraWedge.start(
      deviceId: 'synthetic:ean13=3600523434725;angle=25;pixel=yuy2',
    );
    final seen = await collectUntil(
      wedge,
      (events) => events.whereType<NativeWedgeScan>().isNotEmpty,
    );
    // It keeps sitting under the camera; nothing more may arrive.
    final later = await collectFor(wedge, const Duration(milliseconds: 1500));
    await wedge.stop();

    final statuses = seen.whereType<NativeWedgeStatus>().map((s) => s.state);
    expect(
        statuses,
        containsAllInOrder([
          NativeWedgeState.starting,
          NativeWedgeState.running,
        ]));
    final scan = seen.whereType<NativeWedgeScan>().single;
    expect(scan.text, '3600523434725');
    expect(scan.symbology, 'EAN13');
    expect(scan.confirmations, greaterThanOrEqualTo(2));
    expect(later.whereType<NativeWedgeScan>(), isEmpty);
  }, skip: skip);

  test('preview frames arrive only while asked for, at the size asked',
      () async {
    final wedge = NativeCameraWedge.start(deviceId: 'synthetic:blank');
    await collectUntil(
      wedge,
      (events) => events.any(
        (e) => e is NativeWedgeStatus && e.state == NativeWedgeState.running,
      ),
    );
    wedge.setPreview(maxEdge: 320, interval: const Duration(milliseconds: 50));
    final seen = await collectUntil(
      wedge,
      (events) => events.whereType<NativeWedgePreview>().length >= 3,
    );
    await wedge.stop();

    final preview = seen.whereType<NativeWedgePreview>().first;
    expect(preview.width, 320);
    expect(preview.height, 180);
    expect(preview.luma.length, 320 * 180);
  }, skip: skip);

  test('a refused camera says why and keeps trying', () async {
    final wedge =
        NativeCameraWedge.start(deviceId: 'synthetic:fail=access_denied');
    final seen = await collectUntil(
      wedge,
      (events) => events.any(
        (e) => e is NativeWedgeStatus && e.state == NativeWedgeState.recovering,
      ),
    );
    await wedge.stop();

    final recovering = seen.whereType<NativeWedgeStatus>().firstWhere(
          (s) => s.state == NativeWedgeState.recovering,
        );
    expect(recovering.error, NativeWedgeError.accessDenied);
    expect(
        recovering.retryIn, greaterThanOrEqualTo(const Duration(seconds: 5)));
  }, skip: skip);

  test('stop completes, is final, and can be called twice', () async {
    final wedge = NativeCameraWedge.start(deviceId: 'synthetic:qr=stop-me');
    final stopped = <NativeWedgeState>[];
    wedge.events.listen((event) {
      if (event is NativeWedgeStatus) stopped.add(event.state);
    });
    await collectUntil(
      wedge,
      (events) => events.whereType<NativeWedgeScan>().isNotEmpty,
    );
    await Future.wait([wedge.stop(), wedge.stop()]);

    expect(stopped.last, NativeWedgeState.stopped);
  }, skip: skip);

  test('two wedges in a row can use the same camera', () async {
    // The settings screen switching cameras, or off-then-on: the second must
    // not find the first still holding the device.
    for (var round = 0; round < 3; round++) {
      final wedge =
          NativeCameraWedge.start(deviceId: 'synthetic:qr=round-$round');
      final seen = await collectUntil(
        wedge,
        (events) => events.whereType<NativeWedgeScan>().isNotEmpty,
      );
      await wedge.stop();
      expect(seen.whereType<NativeWedgeScan>().single.text, 'round-$round');
    }
  }, skip: skip);
}
