// Renders «عمليات بحث بلا نتائج» to PNG, headlessly, from the same surfaces as
// lib/dev/search_misses_preview.dart, so the worklist can be looked at on a
// phone, a till and in the dark instead of described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/search_misses_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/search_misses_preview.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

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
    required String name,
    bool dark = false,
    Future<void> Function(WidgetTester tester)? act,
  }) async {
    debugDisableShadows = false;
    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      SearchMissesPreviewApp(
        screen: screen,
        theme: _withButtonFont(dark ? PointyTheme.dark() : PointyTheme.light()),
        now: DateTime(2026, 9, 29, 12),
      ),
    );
    await tester.pumpAndSettle();
    await act?.call(tester);
    await tester.pumpAndSettle();
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/search_misses_$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  final l10n = lookupAppLocalizations(const Locale('ar'));
  const phone = Size(390, 844);
  const wide = Size(1280, 800);

  testWidgets('open, phone', (tester) async {
    await shoot(tester, screen: 'open', size: phone, name: 'open_phone');
  }, skip: !_capture);

  testWidgets('open, wide', (tester) async {
    await shoot(tester, screen: 'open', size: wide, name: 'open_wide');
  }, skip: !_capture);

  testWidgets('open, wide, dark', (tester) async {
    await shoot(
      tester,
      screen: 'open',
      size: wide,
      name: 'open_wide_dark',
      dark: true,
    );
  }, skip: !_capture);

  testWidgets('choosing the product, phone', (tester) async {
    await shoot(
      tester,
      screen: 'open',
      size: phone,
      name: 'picker_phone',
      act: (tester) async {
        await tester.tap(find.text(l10n.searchMissResolveButton).first);
      },
    );
  }, skip: !_capture);

  testWidgets('taught, with the snackbar, wide', (tester) async {
    await shoot(
      tester,
      screen: 'open',
      size: wide,
      name: 'resolved_snackbar_wide',
      act: (tester) async {
        await tester.tap(find.text(l10n.searchMissResolveButton).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('كاتشب هاينز - 575 غ'));
      },
    );
  }, skip: !_capture);

  testWidgets('resolved, wide', (tester) async {
    await shoot(tester, screen: 'resolved', size: wide, name: 'resolved_wide');
  }, skip: !_capture);

  testWidgets('all, phone', (tester) async {
    await shoot(tester, screen: 'all', size: phone, name: 'all_phone');
  }, skip: !_capture);

  testWidgets('empty, phone', (tester) async {
    await shoot(tester, screen: 'empty', size: phone, name: 'empty_phone');
  }, skip: !_capture);
}
