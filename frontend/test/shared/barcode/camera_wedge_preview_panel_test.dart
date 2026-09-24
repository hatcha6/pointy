import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_health.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_preview_panel.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_source.dart';
import 'package:pointy_frontend/src/shared/design/pointy_theme.dart';

class _Source implements CameraWedgeSource {
  final health_ = ValueNotifier(
    const CameraWedgeHealth(state: CameraWedgeState.running),
  );
  final preview_ = ValueNotifier<CameraWedgePreviewFrame?>(null);
  final previewRequests = <bool>[];

  @override
  Stream<CameraWedgeScan> get scans => const Stream.empty();

  @override
  ValueListenable<CameraWedgeHealth> get health => health_;

  @override
  ValueListenable<CameraWedgePreviewFrame?> get preview => preview_;

  @override
  bool get supportsPreview => true;

  @override
  void setPreviewEnabled(bool enabled) => previewRequests.add(enabled);

  @override
  Future<List<CameraWedgeDevice>> devices() async => const [];

  @override
  Future<void> start({String? deviceId}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late _Source source;
  late CameraWedgeController controller;

  setUp(() {
    source = _Source();
    controller = CameraWedgeController(source: source);
  });

  Widget app({CameraWedgeController? wedge, bool useController = true}) {
    // The host sits where it does in the real app: in MaterialApp.builder,
    // above the Navigator.
    return MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => CameraWedgePreviewHost(
        controller: useController ? (wedge ?? controller) : null,
        available: true,
        child: child!,
      ),
      home: const Scaffold(body: Center(child: TextField())),
    );
  }

  final panel = find.byKey(const ValueKey('camera_wedge_preview_panel'));

  testWidgets('F8 opens the camera preview over the screen, and closes it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    expect(panel, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();
    expect(panel, findsOneWidget);
    // Frames are asked for only while the panel is open.
    expect(source.previewRequests, [true]);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();
    expect(panel, findsNothing);
    expect(source.previewRequests, [true, false]);
  });

  testWidgets('F8 works while a text field has focus', (tester) async {
    // The till's catalog search is focused almost all the time.
    await tester.pumpWidget(app());
    await tester.showKeyboard(find.byType(TextField));

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();

    expect(panel, findsOneWidget);
  });

  testWidgets('with a modifier held, F8 is left to whoever else wants it', (
    tester,
  ) async {
    await tester.pumpWidget(app());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(panel, findsNothing);
  });

  testWidgets('without a camera wedge on this machine F8 does nothing', (
    tester,
  ) async {
    // Switched off in settings, or nobody signed in yet: no panel over the
    // login screen.
    await tester.pumpWidget(app(useController: false));

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();

    expect(panel, findsNothing);
  });

  testWidgets('the close button closes it', (tester) async {
    await tester.pumpWidget(app());
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('camera_wedge_preview_close')));
    await tester.pump();

    expect(panel, findsNothing);
  });

  testWidgets('a camera that cannot send a picture shows no picture box', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();
    expect(source.previewRequests, [true]);

    source.health_.value = const CameraWedgeHealth(
      state: CameraWedgeState.recovering,
      fault: CameraWedgeFault.accessDenied,
    );
    await tester.pump();

    // The waiting box is gone, and with it the frames it asked for.
    expect(source.previewRequests, [true, false]);
  });

  testWidgets('it says why the camera is not reading, and what it last read', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();

    source.health_.value = const CameraWedgeHealth(
      state: CameraWedgeState.recovering,
      fault: CameraWedgeFault.inUse,
      lastScan: CameraWedgeScan(
        value: '3600523434725',
        symbology: 'EAN13',
        confirmations: 2,
      ),
    );
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.cameraWedgeFaultInUse), findsOneWidget);
    expect(
      find.byKey(const ValueKey('camera_wedge_last_scan')),
      findsOneWidget,
    );
  });

  testWidgets('a preview frame is painted', (tester) async {
    await tester.pumpWidget(app());
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();

    await tester.runAsync(() async {
      source.preview_.value = CameraWedgePreviewFrame(
        width: 4,
        height: 2,
        luma: Uint8List.fromList(List.generate(8, (i) => i * 30)),
      );
      // Decoding pixels into an image is real engine work.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (find
            .byKey(const ValueKey('camera_wedge_preview_image'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await tester.pump();
      }
    });
    await tester.pump();

    expect(
      find.byKey(const ValueKey('camera_wedge_preview_image')),
      findsOneWidget,
    );
  });
}
