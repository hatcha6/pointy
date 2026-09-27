// Renders lending an employee money to PNG, headlessly, from the same surfaces
// as lib/dev/employee_loans_preview.dart, so the form can be looked at on a
// phone, a till and in the dark instead of described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/employee_loans_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/employee_loans_preview.dart';
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
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: patch(theme.segmentedButtonTheme.style),
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
      EmployeeLoansPreviewApp(
        screen: screen,
        theme: _withButtonFont(dark ? PointyTheme.dark() : PointyTheme.light()),
      ),
    );
    await tester.pumpAndSettle();
    await act?.call(tester);
    await tester.pumpAndSettle();
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/employee_loans_$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) =>
      tap(tester, find.byKey(ValueKey(key)));

  /// Scrolls the form back to its first field without a swipe: dragging a
  /// bottom sheet that has nothing to scroll dismisses it.
  Future<void> scrollToTop(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const ValueKey('employee_loan_employee_field')),
    );
    await tester.pumpAndSettle();
  }

  /// Salem, 600 over three months: the case the form is mostly for.
  Future<void> fillForSalem(WidgetTester tester) async {
    await tapKey(tester, 'employee_loan_employee_field');
    await tester.tap(find.text('سالم علي المسماري').last);
    await tester.pumpAndSettle();
    await type(tester, 'employee_loan_amount', '600');
    await tapKey(tester, 'employee_loan_months_3');
    await type(tester, 'employee_loan_purpose', 'سلفة على الراتب');
    // Back to the top, where the form starts, and the focus with it so the
    // caret is not what the eye lands on.
    FocusManager.instance.primaryFocus?.unfocus();
    await scrollToTop(tester);
  }

  const phone = Size(390, 844);
  const tallPhone = Size(390, 1500);
  const wide = Size(1280, 1100);

  testWidgets('the form as it opens, phone', (tester) async {
    await shoot(tester, screen: 'new', size: phone, name: 'new_phone');
  }, skip: !_capture);

  testWidgets('filled, phone', (tester) async {
    await shoot(
      tester,
      screen: 'new',
      size: tallPhone,
      name: 'filled_phone',
      act: fillForSalem,
    );
  }, skip: !_capture);

  testWidgets('filled, wide', (tester) async {
    await shoot(
      tester,
      screen: 'new',
      size: wide,
      name: 'filled_wide',
      act: fillForSalem,
    );
  }, skip: !_capture);

  testWidgets('filled, wide, dark', (tester) async {
    await shoot(
      tester,
      screen: 'new',
      size: wide,
      name: 'filled_wide_dark',
      dark: true,
      act: fillForSalem,
    );
  }, skip: !_capture);

  testWidgets('by bank transfer, for someone on leave', (tester) async {
    await shoot(
      tester,
      screen: 'new',
      size: wide,
      name: 'bank_wide',
      act: (tester) async {
        await tapKey(tester, 'employee_loan_employee_field');
        await tester.tap(find.text('فاطمة الورفلي').last);
        await tester.pumpAndSettle();
        await type(tester, 'employee_loan_amount', '2000');
        await type(tester, 'employee_loan_monthly', '2500');
        await type(tester, 'employee_loan_monthly', '1900');
        await tapKey(tester, 'loan_source_bank');
      },
    );
  }, skip: !_capture);

  testWidgets('recorded for approval, phone', (tester) async {
    await shoot(
      tester,
      screen: 'request',
      size: tallPhone,
      name: 'request_phone',
      act: fillForSalem,
    );
  }, skip: !_capture);

  testWidgets('what is missing, phone', (tester) async {
    await shoot(
      tester,
      screen: 'new',
      size: phone,
      name: 'errors_phone',
      act: (tester) async {
        await tester.tap(find.byKey(const ValueKey('employee_loan_submit')));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await scrollToTop(tester);
      },
    );
  }, skip: !_capture);

  testWidgets('choosing the employee, phone', (tester) async {
    await shoot(tester, screen: 'picker', size: phone, name: 'picker_phone');
  }, skip: !_capture);

  testWidgets('the loans tab, wide', (tester) async {
    await shoot(
      tester,
      screen: 'payroll',
      size: const Size(1280, 800),
      name: 'tab_wide',
      act: (tester) async {
        await tester.tap(find.text('السلف').first);
        await tester.pumpAndSettle();
      },
    );
  }, skip: !_capture);

  testWidgets('the loans tab, phone', (tester) async {
    await shoot(
      tester,
      screen: 'payroll',
      size: phone,
      name: 'tab_phone',
      act: (tester) async {
        await tester.tap(find.text('السلف').first);
        await tester.pumpAndSettle();
      },
    );
  }, skip: !_capture);

  testWidgets('an employee account, phone', (tester) async {
    await shoot(
      tester,
      screen: 'account',
      size: const Size(390, 1300),
      name: 'account_phone',
    );
  }, skip: !_capture);

  testWidgets('an employee account, wide', (tester) async {
    await shoot(
      tester,
      screen: 'account',
      size: const Size(1280, 1000),
      name: 'account_wide',
    );
  }, skip: !_capture);
}
