import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/device_settings/views/camera_wedge_settings_panel.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_health.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_policy.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_scope.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_source.dart';
import 'package:pointy_frontend/src/shared/design/pointy_theme.dart';

class _Source implements CameraWedgeSource {
  _Source(CameraWedgeHealth health) : health_ = ValueNotifier(health);

  final ValueNotifier<CameraWedgeHealth> health_;
  final preview_ = ValueNotifier<CameraWedgePreviewFrame?>(null);

  @override
  Stream<CameraWedgeScan> get scans => const Stream.empty();

  @override
  ValueListenable<CameraWedgeHealth> get health => health_;

  @override
  ValueListenable<CameraWedgePreviewFrame?> get preview => preview_;

  @override
  bool get supportsPreview => true;

  @override
  void setPreviewEnabled(bool enabled) {}

  @override
  Future<List<CameraWedgeDevice>> devices() async => const [];

  @override
  Future<void> start({String? deviceId}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// Settings says what the CAMERA is doing, not what the switch says: the
/// first version reported "working" while the camera failed a whole shift.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  Widget screen(CameraWedgeController? controller) {
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
      home: CameraWedgeScope(
        controller: controller,
        child: const Scaffold(
          body: SingleChildScrollView(child: CameraWedgeSettingsStatus()),
        ),
      ),
    );
  }

  final privacyButton = find.byKey(
    const ValueKey('camera_wedge_privacy_settings_button'),
  );

  testWidgets('a running camera says so, with what it delivers', (
    tester,
  ) async {
    final controller = CameraWedgeController(
      source: _Source(
        const CameraWedgeHealth(
          state: CameraWedgeState.running,
          width: 1280,
          height: 720,
          fps: 30,
        ),
      ),
    );
    await tester.pumpWidget(screen(controller));

    expect(find.text(l10n.cameraWedgeRunning), findsOneWidget);
    expect(find.textContaining('30'), findsWidgets);
    expect(privacyButton, findsNothing);
  });

  testWidgets('a privacy block says how to fix it, with the button to do it', (
    tester,
  ) async {
    final controller = CameraWedgeController(
      source: _Source(
        const CameraWedgeHealth(
          state: CameraWedgeState.recovering,
          fault: CameraWedgeFault.accessDenied,
        ),
      ),
    );
    await tester.pumpWidget(screen(controller));

    expect(find.text(l10n.cameraWedgeFaultAccessDenied), findsOneWidget);
    expect(privacyButton, findsOneWidget);
    expect(
      CameraWedgeSettingsStatus.privacySettingsUri.toString(),
      'ms-settings:privacy-webcam',
    );
  });

  testWidgets('each fault has its own sentence', (tester) async {
    final source = _Source(CameraWedgeHealth.stopped);
    final controller = CameraWedgeController(source: source);
    await tester.pumpWidget(screen(controller));

    final expected = {
      CameraWedgeFault.noCamera: l10n.cameraWedgeFaultNoCamera,
      CameraWedgeFault.deviceNotFound: l10n.cameraWedgeFaultDeviceNotFound,
      CameraWedgeFault.inUse: l10n.cameraWedgeFaultInUse,
      CameraWedgeFault.deviceLost: l10n.cameraWedgeFaultDeviceLost,
      CameraWedgeFault.stalled: l10n.cameraWedgeFaultStalled,
      CameraWedgeFault.noUsableFormat: l10n.cameraWedgeFaultNoUsableFormat,
      CameraWedgeFault.platform: l10n.cameraWedgeFaultPlatform,
    };
    for (final MapEntry(key: fault, value: message) in expected.entries) {
      source.health_.value = CameraWedgeHealth(
        state: CameraWedgeState.recovering,
        fault: fault,
      );
      await tester.pump();
      expect(find.text(message), findsOneWidget, reason: '$fault');
    }
  });

  testWidgets('a stand-in camera is named, not silently used', (tester) async {
    final controller = CameraWedgeController(
      source: _Source(
        const CameraWedgeHealth(
          state: CameraWedgeState.running,
          deviceLabel: 'HUE HD Pro camera',
          substitutedDevice: true,
        ),
      ),
    );
    await tester.pumpWidget(screen(controller));

    expect(
      find.byKey(const ValueKey('camera_wedge_substituted_message')),
      findsOneWidget,
    );
  });

  testWidgets('before the app has started the camera it says it is starting', (
    tester,
  ) async {
    await tester.pumpWidget(screen(null));

    expect(find.text(l10n.cameraWedgeStarting), findsOneWidget);
  });
}
