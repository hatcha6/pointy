// Renders the counter camera's UI to PNG, headlessly, from the same surfaces
// as lib/dev/camera_wedge_preview.dart: the F8 preview panel (with live,
// drawn frames) and the camera section of device settings in each state.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/camera_wedge_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/camera_wedge_preview.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';

ThemeData _withButtonFont(ThemeData theme) {
  ButtonStyle patch(ButtonStyle? style) {
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) {
        final resolved = style?.textStyle?.resolve(states);
        return (resolved ?? const TextStyle()).copyWith(
          fontFamily: PointyTypography.fontFamily,
        );
      }),
    );
  }

  return theme.copyWith(
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patch(theme.outlinedButtonTheme.style),
    ),
  );
}

String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return Directory(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    // Arabic needs the app's font, and button labels resolve to Roboto, which
    // has no Arabic: point both at IBM Plex Sans Arabic.
    for (final family in const ['IBMPlexSansArabic', 'Roboto']) {
      final loader = FontLoader(family);
      for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(
          rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
        );
      }
      await loader.load();
    }
    final iconFont = File(
      '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
      'MaterialIcons-Regular.otf',
    );
    if (iconFont.existsSync()) {
      final bytes = await iconFont.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
  });

  Future<void> shoot(
    WidgetTester tester, {
    required String screen,
    required Size size,
  }) async {
    debugDisableShadows = false;
    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _withButtonFont(PointyTheme.light()),
        builder: (context, inner) => PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: cameraWedgePreviewSurface(screen),
      ),
    );
    // The fake camera paints a frame every 100 ms and turning one into an
    // image is real engine work, which the fake clock never waits for: step
    // out of it long enough for the previews to show a picture. Not
    // pumpAndSettle — a live preview never settles.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/camera_wedge_$screen.png'),
      );
    } finally {
      debugDisableShadows = true;
      // Unmount, which releases the previews and stops the fake cameras'
      // frame timers before the test checks for pending ones.
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }

  testWidgets('every state at once', (tester) async {
    await shoot(tester, screen: 'board', size: const Size(1300, 1750));
  }, skip: !_capture);

  testWidgets('the F8 panel over the till', (tester) async {
    await shoot(tester, screen: 'panel', size: const Size(1280, 800));
  }, skip: !_capture);

  testWidgets('settings, phone width', (tester) async {
    await shoot(tester, screen: 'settings', size: const Size(430, 2100));
  }, skip: !_capture);
}
