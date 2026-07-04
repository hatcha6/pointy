import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';

void main() {
  Future<({List<String> scanned, List<String> typed, List<LogicalKeyboardKey> arrows})>
  pumpListener(WidgetTester tester) async {
    final scanned = <String>[];
    final typed = <String>[];
    final arrows = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeScanListener(
          onBarcodeScanned: scanned.add,
          onDigitsTyped: typed.add,
          onArrowKey: (key) {
            arrows.add(key);
            return true;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    return (scanned: scanned, typed: typed, arrows: arrows);
  }

  testWidgets('a slowly typed digit fires onDigitsTyped, not a scan', (
    tester,
  ) async {
    final events = await pumpListener(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    // Past the human-digit delay with no further keys → human typing.
    await tester.pump(const Duration(milliseconds: 250));

    expect(events.typed, ['5']);
    expect(events.scanned, isEmpty);
  });

  testWidgets('a scanner burst submits the barcode and never fires digits', (
    tester,
  ) async {
    final events = await pumpListener(tester);

    for (final key in [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 250));

    expect(events.scanned, ['12345678']);
    expect(events.typed, isEmpty);
  });

  testWidgets('a terminator-less digit string longer than a quantity is '
      'neither scanned nor typed', (tester) async {
    final events = await pumpListener(tester);

    for (final key in [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.pump(const Duration(milliseconds: 400));

    expect(events.scanned, isEmpty);
    expect(events.typed, isEmpty);
  });

  testWidgets('arrow keys reach onArrowKey', (tester) async {
    final events = await pumpListener(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);

    expect(events.arrows, [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
    ]);
  });

  testWidgets('typing into a focused text field never triggers the quick '
      'shortcuts', (tester) async {
    final typed = <String>[];
    final arrows = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeScanListener(
          onBarcodeScanned: (_) {},
          onDigitsTyped: typed.add,
          onArrowKey: (key) {
            arrows.add(key);
            return true;
          },
          child: const Material(child: TextField(autofocus: true)),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.digit7);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 400));

    expect(typed, isEmpty);
    expect(arrows, isEmpty);
  });
}
