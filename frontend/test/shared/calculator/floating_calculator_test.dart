import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';
import 'package:pointy_frontend/src/shared/calculator/floating_calculator.dart';
import 'package:pointy_frontend/src/shared/decimal_text_input_formatter.dart';
import 'package:pointy_frontend/src/shared/design/pointy_theme.dart';

void main() {
  late DateTime now;
  late TextEditingController field;
  late List<String> changes;
  late List<String> scans;
  late GlobalKey<FloatingCalculatorHostState> hostKey;

  setUp(() {
    now = DateTime(2026, 10, 13, 12);
    field = TextEditingController();
    changes = [];
    scans = [];
    hostKey = GlobalKey<FloatingCalculatorHostState>();
  });

  DateTime clock() => now;

  // The host sits where it does in the real app: in MaterialApp.builder,
  // around the Navigator. The page is a till-like screen: a money field and
  // the barcode listener.
  Widget app({bool enabled = true}) {
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
      builder: (context, child) => FloatingCalculatorHost(
        key: hostKey,
        enabled: enabled,
        clock: clock,
        child: child!,
      ),
      home: Scaffold(
        body: BarcodeScanListener(
          clock: clock,
          onBarcodeScanned: scans.add,
          child: Center(
            child: SizedBox(
              width: 200,
              child: TextField(
                key: const ValueKey('amount'),
                controller: field,
                inputFormatters: [DecimalTextInputFormatter()],
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Finder panel() => find.byKey(const ValueKey('floating_calculator_panel'));

  String result(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('floating_calculator_result')),
          matching: find.byType(Text),
        ),
      )
      .data!
      // The display wraps its lines in LTR isolates.
      .replaceAll(RegExp('[\u2066\u2069]'), '');

  String expression(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('floating_calculator_expression')),
          matching: find.byType(Text),
        ),
      )
      .data!
      // The display wraps its lines in LTR isolates.
      .replaceAll(RegExp('[\u2066\u2069]'), '');

  /// Types like a person: each key well apart from the last.
  Future<void> type(WidgetTester tester, String keys) async {
    for (final char in keys.split('')) {
      now = now.add(const Duration(milliseconds: 200));
      // Symbols as a US keyboard sends them: the key's own logical/physical
      // pair, with the typed character on top.
      final (logical, physical) = switch (char) {
        '+' => (LogicalKeyboardKey.equal, PhysicalKeyboardKey.equal),
        '-' => (LogicalKeyboardKey.minus, PhysicalKeyboardKey.minus),
        '*' => (LogicalKeyboardKey.digit8, PhysicalKeyboardKey.digit8),
        '/' => (LogicalKeyboardKey.slash, PhysicalKeyboardKey.slash),
        '%' => (LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
        '.' => (LogicalKeyboardKey.period, PhysicalKeyboardKey.period),
        '=' => (LogicalKeyboardKey.equal, PhysicalKeyboardKey.equal),
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

  Future<void> pressF12(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();
  }

  testWidgets('F12 opens it with the keyboard, F12 again closes', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    expect(panel(), findsNothing);

    await pressF12(tester);
    expect(panel(), findsOneWidget);

    await type(tester, '200+20%');
    expect(expression(tester), '200+20%');
    expect(result(tester), '= 240');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(result(tester), '240');
    expect(expression(tester), '200+20% =');

    await pressF12(tester);
    expect(panel(), findsNothing);
  });

  testWidgets('a modifier with F12 is not the shortcut', (tester) async {
    await tester.pumpWidget(app());
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(panel(), findsNothing);
  });

  testWidgets('disabled (price-checker kiosk): F12 does nothing', (
    tester,
  ) async {
    await tester.pumpWidget(app(enabled: false));
    await pressF12(tester);
    expect(panel(), findsNothing);
  });

  testWidgets('keypad buttons work and take the keyboard', (tester) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    for (final key in ['nine', 'multiply', 'four', 'equals']) {
      await tester.tap(find.byKey(ValueKey('calculator_key_$key')));
    }
    await tester.pump();
    expect(result(tester), '36');
  });

  testWidgets('Esc clears, Esc again closes and hands focus back', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('amount')));
    await tester.pump();
    final fieldFocus = FocusManager.instance.primaryFocus;

    await pressF12(tester);
    expect(FocusManager.instance.primaryFocus, isNot(fieldFocus));
    await type(tester, '12');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(panel(), findsOneWidget);
    expect(expression(tester), '0');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel(), findsNothing);
    expect(FocusManager.instance.primaryFocus, fieldFocus);
    // The digits went to the calculator, never to the field.
    expect(field.text, isEmpty);
  });

  testWidgets('F12 while open but unfocused takes the keyboard back first', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    await tester.tap(find.byKey(const ValueKey('amount')));
    await tester.pump();
    expect(panel(), findsOneWidget);

    await pressF12(tester);
    expect(panel(), findsOneWidget);
    await type(tester, '7');
    expect(expression(tester), '7');
    expect(field.text, isEmpty);
  });

  testWidgets('Shift+Enter types the answer into the field it came from', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('amount')));
    await tester.pump();
    await pressF12(tester);
    await type(tester, '12*3');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(field.text, '36');
    // Through the field's own input path: onChanged fired.
    expect(changes, ['36']);
    expect(panel(), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>()
          ?.key,
      const ValueKey('amount'),
    );
  });

  testWidgets('the insert button does the same', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('amount')));
    await tester.pump();
    await pressF12(tester);
    await type(tester, '1/4');
    await tester.tap(find.byKey(const ValueKey('floating_calculator_insert')));
    await tester.pumpAndSettle();
    expect(field.text, '0.25');
  });

  testWidgets('a field that refuses the value says so', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('amount')));
    await tester.pump();
    await pressF12(tester);
    // The money field takes no minus sign.
    await type(tester, '5-8=');
    await tester.tap(find.byKey(const ValueKey('floating_calculator_insert')));
    await tester.pumpAndSettle();
    expect(field.text, isEmpty);
    expect(panel(), findsOneWidget);
    expect(
      find.byKey(const ValueKey('floating_calculator_notice')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('without a field to insert into, there is no insert button', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    await type(tester, '5');
    expect(
      find.byKey(const ValueKey('floating_calculator_insert')),
      findsNothing,
    );
  });

  testWidgets('with a field, the insert button appears once there is a value', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('amount')));
    await tester.pump();
    await pressF12(tester);
    expect(
      find.byKey(const ValueKey('floating_calculator_insert')),
      findsNothing,
    );
    await type(tester, '5');
    expect(
      find.byKey(const ValueKey('floating_calculator_insert')),
      findsOneWidget,
    );
  });

  testWidgets('a scan while the calculator has the keyboard goes to the '
      'till, and the calculator takes back what it typed', (tester) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    await type(tester, '5+');
    expect(expression(tester), '5+');

    // A wedge, a moment later: 13 digits 10 ms apart, then Enter.
    now = now.add(const Duration(seconds: 1));
    for (final digit in '6291041500213'.split('')) {
      now = now.add(const Duration(milliseconds: 10));
      await tester.sendKeyEvent(
        LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(digit)),
        character: digit,
      );
    }
    now = now.add(const Duration(milliseconds: 10));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(scans, ['6291041500213']);
    expect(expression(tester), '5+');
    expect(find.textContaining('6291041500218'), findsNothing);
  });

  testWidgets('a fast human (two rolled digits) is not a scanner', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    now = now.add(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '1');
    now = now.add(const Duration(milliseconds: 30));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2, character: '2');
    await tester.pump();
    expect(expression(tester), '12');
    expect(scans, isEmpty);
  });

  testWidgets('Arabic-Indic digits and ٪ from an Arabic keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    for (final char in ['٢', '٠', '٠', '+', '١', '٠', '٪']) {
      now = now.add(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: char);
    }
    await tester.pump();
    expect(result(tester), '= 220');
  });

  testWidgets('the numpad works whatever the layout types', (tester) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    for (final key in [
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpadMultiply,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpadEnter,
    ]) {
      now = now.add(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(key);
    }
    await tester.pump();
    expect(result(tester), '20');
  });

  testWidgets('Ctrl+C copies the plain answer', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(app());
    await pressF12(tester);
    await type(tester, '1000*3=');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, '3000');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the tape keeps earlier answers and reuses them', (tester) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    await type(tester, '2+2=');
    await tester.tap(find.byKey(const ValueKey('floating_calculator_history')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('floating_calculator_history_list')),
      findsOneWidget,
    );
    await type(tester, '10+');
    await tester.tap(find.textContaining('= 4'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(result(tester), '14');
  });

  testWidgets('the tape is a sheet: Esc lowers it before anything else', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    await type(tester, '6*7=');
    await tester.tap(find.byKey(const ValueKey('floating_calculator_history')));
    await tester.pumpAndSettle();
    final sheet = find.byKey(
      const ValueKey('floating_calculator_history_list'),
    );
    final panelRect = tester.getRect(panel());
    // Risen from the panel's bottom edge, inside the panel.
    expect(tester.getRect(sheet).bottom, closeTo(panelRect.bottom, 2));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.getRect(sheet).top, greaterThanOrEqualTo(panelRect.bottom));
    // The result is still there: that Esc only lowered the sheet.
    expect(result(tester), '42');
  });

  testWidgets('the tape and position survive closing', (tester) async {
    await tester.pumpWidget(app());
    await pressF12(tester);
    await type(tester, '3*3=');
    await pressF12(tester);
    await pressF12(tester);
    expect(hostKey.currentState!.controller.history.single.expression, '3×3');
  });

  testWidgets('fits a phone-width screen', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await pressF12(tester);
    expect(tester.takeException(), isNull);
    final rect = tester.getRect(panel());
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(360));
  });
}
