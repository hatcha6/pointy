import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/companion/companion_bridge.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'package:pointy_frontend/src/shared/barcode/keystroke_wedge.dart';
import 'package:pointy_frontend/src/shared/barcode/scan_keyboard.dart';

import '../../support/fake_camera_wedge_source.dart';
import '../../support/fake_companion_bridge.dart';

/// The counter camera and a paired phone, wired the way `app.dart` wires
/// them: above the Navigator, heard by screens only as keystrokes.
void main() {
  late FakeCameraWedgeSource camera;
  late CameraWedgeController controller;
  late FakeCompanionBridge phone;

  setUp(() {
    camera = FakeCameraWedgeSource();
    controller = CameraWedgeController(source: camera);
    phone = FakeCompanionBridge();
  });

  tearDown(() {
    controller.dispose();
    phone.dispose();
  });

  Widget devices({
    required Widget home,
    CameraWedgeController? camera,
    CompanionBridge? phone,
    Map<String, WidgetBuilder> routes = const {},
  }) {
    return MaterialApp(
      builder: (context, navigator) => ScanKeyboard<CameraWedgeController>(
        source: 'camera_wedge',
        device: camera,
        scans: (camera) => camera.scans.map((scan) => scan.value),
        child: ScanKeyboard<CompanionBridge>(
          source: 'companion_camera',
          device: phone,
          scans: (phone) => phone.scans,
          child: navigator ?? const SizedBox.shrink(),
        ),
      ),
      home: home,
      routes: routes,
    );
  }

  /// A screen with a scan listener, recording each scan and what typed it.
  Widget screen(List<String> scanned, {List<String?>? sources}) {
    return BarcodeScanListener(
      onBarcodeScanned: (value) {
        scanned.add(value);
        sources?.add(KeystrokeWedge.typingSource);
      },
      child: const Scaffold(body: Text('till')),
    );
  }

  testWidgets('a QR the camera confirms is typed to the screen', (
    tester,
  ) async {
    final scanned = <String>[];
    final sources = <String?>[];
    await tester.pumpWidget(
      devices(
        home: screen(scanned, sources: sources),
        camera: controller,
      ),
    );
    await controller.start();

    camera.see('pay://receipt/9f2');
    await tester.pump();

    // A QR is error-corrected, so one look is enough — which is the point of
    // the camera for payment-terminal receipts the counter wedge cannot read.
    expect(scanned, ['pay://receipt/9f2']);
    expect(sources, ['camera_wedge']);
  });

  testWidgets('a 1-D read is typed only once a second look agrees', (
    tester,
  ) async {
    final scanned = <String>[];
    await tester.pumpWidget(devices(home: screen(scanned), camera: controller));
    await controller.start();

    camera.see('3600523434725', symbology: 'EAN13');
    await tester.pump();
    expect(scanned, isEmpty);

    camera.see('3600523434725', symbology: 'EAN13');
    await tester.pump();
    expect(scanned, ['3600523434725']);
  });

  testWidgets('a measured misread is never typed', (tester) async {
    // The exact values the lab recorded off one product, each checksum-valid
    // and each wrong. Interleaved with the truth, as they arrived.
    final scanned = <String>[];
    await tester.pumpWidget(devices(home: screen(scanned), camera: controller));
    await controller.start();

    for (final value in [
      '3600523434725',
      '9660323434725',
      '0608713434725',
      '9620723434725',
    ]) {
      camera.see(value, symbology: 'EAN13');
      await tester.pump();
    }

    expect(scanned, isEmpty);
    expect(camera.policy.rejectedDisagreements, 3);
  });

  testWidgets("a phone's scan is typed to the screen", (tester) async {
    final scanned = <String>[];
    final sources = <String?>[];
    await tester.pumpWidget(
      devices(
        home: screen(scanned, sources: sources),
        phone: phone,
      ),
    );

    phone.emitScan('6291041500213');
    await tester.pump();

    expect(scanned, ['6291041500213']);
    expect(sources, ['companion_camera']);
  });

  testWidgets('a scan stops at a screen a dialog is covering, and reaches '
      'it again once the dialog is gone', (tester) async {
    final scanned = <String>[];
    late BuildContext screenContext;
    await tester.pumpWidget(
      devices(
        phone: phone,
        camera: controller,
        home: BarcodeScanListener(
          onBarcodeScanned: scanned.add,
          child: Builder(
            builder: (context) {
              screenContext = context;
              return const Scaffold(body: Text('till'));
            },
          ),
        ),
      ),
    );
    await controller.start();

    // Without route gating the till under an open payment sheet would try to
    // make a product out of the receipt QR scanned into that sheet.
    unawaited(
      showDialog<void>(
        context: screenContext,
        builder: (context) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();

    phone.emitScan('6291041500213');
    camera.see('pay://receipt/9f2');
    await tester.pumpAndSettle();
    expect(scanned, isEmpty);

    Navigator.of(screenContext).pop();
    await tester.pumpAndSettle();

    phone.emitScan('6291041500213');
    await tester.pumpAndSettle();
    expect(scanned, ['6291041500213'], reason: 'the screen hears again');
  });

  testWidgets('a busy screen drops a scan rather than queueing it', (
    tester,
  ) async {
    final scanned = <String>[];
    Widget till({required bool enabled}) => devices(
      camera: controller,
      home: BarcodeScanListener(
        enabled: enabled,
        onBarcodeScanned: scanned.add,
        child: const Scaffold(body: Text('till')),
      ),
    );
    await tester.pumpWidget(till(enabled: false));
    await controller.start();

    camera.see('pay://receipt/9f2');
    await tester.pump();
    expect(scanned, isEmpty);

    // And becoming free must not deliver the one that arrived mid-checkout.
    await tester.pumpWidget(till(enabled: true));
    await tester.pump();
    expect(scanned, isEmpty);
  });

  testWidgets('a scan lands in whatever field has focus, as a scanner '
      "would, on screens that never heard of these devices", (tester) async {
    final submitted = <String>[];
    final field = TextEditingController();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      devices(
        phone: phone,
        home: Scaffold(
          body: TextField(
            controller: field,
            autofocus: true,
            onSubmitted: submitted.add,
          ),
        ),
      ),
    );
    await tester.pump();

    phone.emitScan('INV-2026/0042');
    await tester.pump();

    expect(field.text, 'INV-2026/0042');
    expect(submitted, ['INV-2026/0042']);
  });

  testWidgets('a device that goes away stops typing; its replacement types', (
    tester,
  ) async {
    final scanned = <String>[];
    await tester.pumpWidget(devices(home: screen(scanned), phone: phone));

    final replacement = FakeCompanionBridge();
    addTearDown(replacement.dispose);
    await tester.pumpWidget(devices(home: screen(scanned), phone: replacement));

    phone.emitScan('from-the-old-phone');
    replacement.emitScan('from-the-new-phone');
    await tester.pump();

    expect(scanned, ['from-the-new-phone']);
  });

  testWidgets('no device means nothing happens at all', (tester) async {
    final scanned = <String>[];
    await tester.pumpWidget(devices(home: screen(scanned)));
    await tester.pump();

    expect(find.text('till'), findsOneWidget);
    expect(scanned, isEmpty);
  });
}
