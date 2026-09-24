// Renders the device printers settings to PNG, headlessly, from the same
// surfaces as lib/dev/printers_preview.dart, so the screen can be looked at
// instead of described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/printers_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/printers_preview.dart';
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
    filledButtonTheme: FilledButtonThemeData(
      style: patch(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patch(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: patch(theme.textButtonTheme.style),
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
    String? name,
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
        home: printersPreviewSurface(screen),
      ),
    );
    await tester.pumpAndSettle();
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/printers_${name ?? screen}.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  const phone = Size(430, 1700);
  const wide = Size(1100, 1500);

  testWidgets('settings, wide', (tester) async {
    await shoot(tester, screen: 'settings', size: wide, name: 'settings_wide');
  }, skip: !_capture);

  testWidgets('settings, phone', (tester) async {
    await shoot(
      tester,
      screen: 'settings',
      size: phone,
      name: 'settings_phone',
    );
  }, skip: !_capture);

  testWidgets('right after the update', (tester) async {
    await shoot(tester, screen: 'migrated', size: wide);
  }, skip: !_capture);

  testWidgets('no printers', (tester) async {
    await shoot(tester, screen: 'empty', size: const Size(900, 900));
  }, skip: !_capture);

  testWidgets('add a printer', (tester) async {
    await shoot(tester, screen: 'add', size: const Size(1280, 1400));
  }, skip: !_capture);

  testWidgets('edit the receipt printer', (tester) async {
    await shoot(tester, screen: 'edit-receipt', size: const Size(1280, 1800));
  }, skip: !_capture);

  testWidgets('edit the label printer, phone', (tester) async {
    await shoot(tester, screen: 'edit-labels', size: const Size(430, 2600));
  }, skip: !_capture);
}
