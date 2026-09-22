import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_listener.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_source.dart';

/// A source under the test's control, standing in for a camera.
class _FakeSource implements CameraWedgeSource {
  final _controller = StreamController<CameraWedgeReading>.broadcast();
  bool started = false;

  void see(String value, {String symbology = 'QRCode'}) =>
      _controller.add(CameraWedgeReading(value: value, symbology: symbology));

  @override
  Stream<CameraWedgeReading> get readings => _controller.stream;

  @override
  Future<List<CameraWedgeDevice>> devices() async =>
      const [CameraWedgeDevice(id: 'x', label: 'x')];

  @override
  Future<void> start({String? deviceId}) async => started = true;

  @override
  Future<void> stop() async => started = false;

  @override
  Future<void> dispose() async => _controller.close();
}

void main() {
  late _FakeSource source;
  late CameraWedgeController controller;
  late List<String> scanned;

  setUp(() {
    source = _FakeSource();
    controller = CameraWedgeController(source: source);
    scanned = [];
  });

  tearDown(() => controller.dispose());

  Widget harness({bool enabled = true, Widget? cover}) {
    return MaterialApp(
      home: CameraWedgeListener(
        controller: controller,
        enabled: enabled,
        onScan: scanned.add,
        child: const Scaffold(body: Text('till')),
      ),
      routes: {'/cover': (_) => cover ?? const Scaffold(body: Text('sheet'))},
    );
  }

  testWidgets('a confirmed scan reaches the screen handler', (tester) async {
    await tester.pumpWidget(harness());
    await controller.start();

    source.see('pay://receipt/9f2');
    await tester.pump();

    // A QR is error-corrected, so one look is enough — which is the point of
    // the camera for payment-terminal receipts the counter wedge cannot read.
    expect(scanned, ['pay://receipt/9f2']);
  });

  testWidgets('an unconfirmed 1-D read reaches nothing', (tester) async {
    await tester.pumpWidget(harness());
    await controller.start();

    source.see('3600523434725', symbology: 'EAN13');
    await tester.pump();

    expect(scanned, isEmpty);

    source.see('3600523434725', symbology: 'EAN13');
    await tester.pump();

    expect(scanned, ['3600523434725']);
  });

  testWidgets('a measured misread never reaches the screen', (tester) async {
    // The exact values the lab recorded off one product, each checksum-valid
    // and each wrong. Interleaved with the truth, as they arrived.
    await tester.pumpWidget(harness());
    await controller.start();

    for (final value in [
      '3600523434725',
      '9660323434725',
      '0608713434725',
      '9620723434725',
    ]) {
      source.see(value, symbology: 'EAN13');
      await tester.pump();
    }

    expect(scanned, isEmpty);
    expect(controller.rejectedDisagreements, 3);
  });

  testWidgets('a disabled screen drops scans rather than queueing them', (
    tester,
  ) async {
    await tester.pumpWidget(harness(enabled: false));
    await controller.start();

    source.see('pay://receipt/9f2');
    await tester.pump();

    expect(scanned, isEmpty);

    // And re-enabling must not deliver the one that arrived mid-checkout.
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(scanned, isEmpty);
  });

  testWidgets('a covered route does not hear the camera', (tester) async {
    // A receipt QR scanned INTO an open payment sheet must not also be read by
    // the POS behind it, which would try to add a product for it.
    await tester.pumpWidget(harness());
    await controller.start();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.pushNamed('/cover'));
    await tester.pumpAndSettle();

    source.see('pay://receipt/9f2');
    await tester.pump();

    expect(scanned, isEmpty);
  });

  testWidgets('a null controller is simply inert', (tester) async {
    // Every screen wires this in unconditionally; platforms with no camera
    // source, and every widget test, pass null and behave exactly as before.
    await tester.pumpWidget(
      MaterialApp(
        home: CameraWedgeListener(
          controller: null,
          onScan: scanned.add,
          child: const Scaffold(body: Text('till')),
        ),
      ),
    );

    expect(find.text('till'), findsOneWidget);
    expect(scanned, isEmpty);
  });
}
