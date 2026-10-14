import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/shared/calculator/currency_converter.dart';
import 'package:pointy_frontend/src/shared/calculator/floating_calculator.dart';
import 'package:pointy_frontend/src/shared/design/pointy_theme.dart';

import 'converter_fixtures.dart';

void main() {
  late DateTime now;
  late TextEditingController field;
  late GlobalKey<FloatingCalculatorHostState> hostKey;
  late Result<ConverterRates> Function() answer;
  late int loads;

  setUp(() {
    now = DateTime(2026, 10, 13, 12);
    field = TextEditingController();
    hostKey = GlobalKey<FloatingCalculatorHostState>();
    loads = 0;
    answer = () => Ok(sampleConverterRates(loadedAt: now));
  });

  Future<Result<ConverterRates>> loader() async {
    loads++;
    return answer();
  }

  Widget app({bool withRates = true}) => MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    builder: (context, child) => FloatingCalculatorHost(
      key: hostKey,
      clock: () => now,
      ratesLoader: withRates ? loader : null,
      ratesKey: withRates ? 1 : null,
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          child: TextField(key: const ValueKey('amount'), controller: field),
        ),
      ),
    ),
  );

  String clean(String text) => text.replaceAll(RegExp('[\u2066\u2069]'), '');

  String value(WidgetTester tester, String side) => clean(
    tester
        .widget<Text>(find.byKey(ValueKey('calculator_converter_value_$side')))
        .data!,
  );

  String chip(WidgetTester tester, String side) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('calculator_currency_$side')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  Future<void> type(WidgetTester tester, String keys) async {
    for (final char in keys.split('')) {
      now = now.add(const Duration(milliseconds: 200));
      final (logical, physical) = switch (char) {
        '+' => (LogicalKeyboardKey.equal, PhysicalKeyboardKey.equal),
        '%' => (LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
        '=' => (LogicalKeyboardKey.equal, PhysicalKeyboardKey.equal),
        '.' => (LogicalKeyboardKey.period, PhysicalKeyboardKey.period),
        _ => (
          LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(char)),
          null,
        ),
      };
      await tester.sendKeyEvent(
        logical,
        physicalKey: physical,
        character: char,
      );
    }
    await tester.pump();
  }

  /// The picker stays mounted while it slides away: shown means risen.
  bool pickerShown(WidgetTester tester) {
    final picker = find.byKey(const ValueKey('calculator_currency_picker'));
    if (picker.evaluate().isEmpty) {
      return false;
    }
    final panel = find.byKey(const ValueKey('floating_calculator_panel'));
    return tester.getRect(picker).top < tester.getRect(panel).bottom - 1;
  }

  Future<void> openConverting(WidgetTester tester) async {
    // A till-sized window: Convert's two rows make the panel taller than the
    // default 800×600 test surface.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('floating_calculator_convert')));
    await tester.pumpAndSettle();
  }

  testWidgets('no Convert toggle for a user who may not read rates', (
    tester,
  ) async {
    await tester.pumpWidget(app(withRates: false));
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('floating_calculator_convert')),
      findsNothing,
    );
  });

  testWidgets('USD above (typed into), dinars below, converted live', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    expect(loads, 1);
    expect(chip(tester, 'top'), 'USD');
    expect(chip(tester, 'bottom'), 'LYD');
    expect(value(tester, 'top'), '0');
    expect(value(tester, 'bottom'), '0.000');

    await type(tester, '200+20%');
    expect(value(tester, 'top'), '200+20%');
    // 240 × 7.15, padded to the dinar's three decimals.
    expect(value(tester, 'bottom'), '1,716.000');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(value(tester, 'top'), '240');
    expect(value(tester, 'bottom'), '1,716.000');
  });

  testWidgets('mid-expression the converted line holds the last whole value', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    await type(tester, '100+');
    expect(value(tester, 'bottom'), '715.000');
  });

  testWidgets('Tab swaps the direction and keeps the typed number', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    await type(tester, '240');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(value(tester, 'bottom'), '240');
    // 240 LYD in dollars, two decimals.
    expect(value(tester, 'top'), '33.57');
    // Typing now goes into the dinar row.
    await type(tester, '0');
    expect(value(tester, 'bottom'), '2,400');
  });

  testWidgets('tapping the converted row makes it the input with its value', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    await type(tester, '5');
    await tester.tap(
      find.byKey(const ValueKey('calculator_converter_row_bottom')),
    );
    await tester.pump();
    expect(value(tester, 'bottom'), '35.75');
    expect(value(tester, 'top'), '5.00');
  });

  testWidgets('the picker: search, no results, the other side greyed, pick', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    await type(tester, '10');
    await tester.tap(find.byKey(const ValueKey('calculator_currency_top')));
    await tester.pumpAndSettle();
    expect(pickerShown(tester), isTrue);

    // The dinar is the other row's: tapping it does nothing.
    await tester.tap(
      find.byKey(const ValueKey('calculator_currency_option_LYD')),
    );
    await tester.pump();
    expect(chip(tester, 'top'), 'USD');

    // Typing goes to the search field, never to the calculator.
    await tester.enterText(
      find.byKey(const ValueKey('calculator_currency_search')),
      'zzz',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('calculator_currency_no_results')),
      findsOneWidget,
    );

    // Arabic, with a letter variant: «يورو» finds the euro.
    await tester.enterText(
      find.byKey(const ValueKey('calculator_currency_search')),
      'يورو',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('calculator_currency_option_EUR')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('calculator_currency_option_TND')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('calculator_currency_option_EUR')),
    );
    await tester.pumpAndSettle();

    expect(chip(tester, 'top'), 'EUR');
    // The number stayed; now it is euros: 10 × 7.8.
    expect(value(tester, 'top'), '10');
    expect(value(tester, 'bottom'), '78.000');
  });

  testWidgets('keys typed in the picker search do not reach the calculator', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    await type(tester, '7');
    await tester.tap(find.byKey(const ValueKey('calculator_currency_top')));
    await tester.pumpAndSettle();
    await type(tester, '12');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(pickerShown(tester), isFalse);
    expect(value(tester, 'top'), '7');
  });

  testWidgets('↓ and Enter pick from the keyboard', (tester) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    await tester.tap(find.byKey(const ValueKey('calculator_currency_top')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('calculator_currency_search')),
      'dinar',
    );
    await tester.pump();
    // LYD (greyed) is skipped: the first pickable dinar is the Tunisian.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(chip(tester, 'top'), 'TND');
  });

  testWidgets('recently picked currencies come first', (tester) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    hostKey.currentState!.converter.pick('EUR', top: true);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('calculator_currency_top')));
    await tester.pumpAndSettle();
    expect(find.text('المستخدمة مؤخرًا'), findsOneWidget);
  });

  testWidgets('rates that fail to load: says so, and retry recovers', (
    tester,
  ) async {
    answer = () => Error(Exception('offline'));
    await tester.pumpWidget(app());
    await openConverting(tester);
    expect(
      find.byKey(const ValueKey('calculator_converter_unavailable')),
      findsOneWidget,
    );
    answer = () => Ok(sampleConverterRates(loadedAt: now));
    await tester.tap(find.byKey(const ValueKey('calculator_converter_retry')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calculator_currency_top')),
      findsOneWidget,
    );
  });

  testWidgets('a stale rate still converts, flagged with its age', (
    tester,
  ) async {
    answer = () => Ok(
      ConverterRates.from(
        sampleCurrentRates(staleEur: true),
        sampleRegistry,
        loadedAt: now,
      ),
    );
    await tester.pumpWidget(app());
    await openConverting(tester);
    hostKey.currentState!.converter.pick('EUR', top: true);
    await tester.pump();
    final line = find.byKey(const ValueKey('calculator_converter_rate_line'));
    expect(
      find.descendant(of: line, matching: find.textContaining('سعر قديم')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: line, matching: find.textContaining('منذ 2 يوم')),
      findsOneWidget,
    );
  });

  testWidgets('a failed refresh keeps converting with the last rates', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    answer = () => Error(Exception('offline'));
    await tester.tap(
      find.byKey(const ValueKey('calculator_converter_refresh')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calculator_converter_refresh_failed')),
      findsOneWidget,
    );
    await type(tester, '1');
    expect(value(tester, 'bottom'), '7.150');
  });

  testWidgets('insert puts the converted amount in the field', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('amount')));
    await tester.pump();
    await openConverting(tester);
    await type(tester, '3');
    await tester.tap(find.byKey(const ValueKey('floating_calculator_insert')));
    await tester.pumpAndSettle();
    expect(field.text, '21.45');
  });

  testWidgets('Convert stays on across closing and reopening', (tester) async {
    await tester.pumpWidget(app());
    await openConverting(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calculator_currency_top')),
      findsOneWidget,
    );
    // Fresh rates are not fetched again within ten minutes.
    expect(loads, 1);
  });
}
