import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_shortcuts_sheet.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_controller.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_wedge/camera_wedge_scope.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../support/fake_camera_wedge_source.dart';
import '../../../support/shortcut_sheet_reading.dart';

/// The till's cheat sheet, on the shared one: modifier keys read as combos,
/// the held-invoice keys as either/or, and F8 only where a camera answers it.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  Future<void> openSheet(
    WidgetTester tester, {
    CameraWedgeController? camera,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        // Above the Navigator, where the app installs it.
        builder: (context, child) =>
            CameraWedgeScope(controller: camera, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPosShortcutsSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('combos join with "+", the invoice keys with "/"', (
    tester,
  ) async {
    await openSheet(tester);

    expect(find.text(l10n.posShortcutsTitle), findsOneWidget);
    expect(find.text(l10n.posShortcutsSubtitle), findsOneWidget);
    expect(shortcutKeysBeside(tester, l10n.posShortcutCheckout), [
      'Ctrl',
      '+',
      'Enter',
    ]);
    expect(shortcutKeysBeside(tester, l10n.posShortcutPayCard), [
      'Ctrl',
      '+',
      '2',
    ]);
    expect(shortcutKeysBeside(tester, l10n.posShortcutCycleInvoices), [
      'Page ↓',
      '/',
      'Page ↑',
    ]);
    // No counter camera here, and F8 does nothing without one.
    expect(find.text(l10n.posShortcutCameraPreview), findsNothing);
  });

  testWidgets('F8 is listed on a till with a counter camera', (tester) async {
    final camera = CameraWedgeController(source: FakeCameraWedgeSource());
    addTearDown(camera.dispose);
    await openSheet(tester, camera: camera);
    expect(shortcutKeysBeside(tester, l10n.posShortcutCameraPreview), ['F8']);
  });
}
