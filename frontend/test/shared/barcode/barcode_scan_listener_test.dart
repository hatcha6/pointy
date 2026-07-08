import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';

void main() {
  Future<({List<String> scanned, List<LogicalKeyboardKey> arrows})> pumpListener(
    WidgetTester tester,
  ) async {
    final scanned = <String>[];
    final arrows = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeScanListener(
          onBarcodeScanned: scanned.add,
          onArrowKey: (key) {
            arrows.add(key);
            return true;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    return (scanned: scanned, arrows: arrows);
  }

  testWidgets('a scanner burst submits the barcode', (tester) async {
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
  });

  testWidgets('typed digits never fire anything but a terminated scan — a '
      'scan can never signal a quantity', (tester) async {
    final events = await pumpListener(tester);

    // Digits typed slowly, without a terminator, produce no callback at all:
    // there is no digit → quantity path a scanner could ever trip.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.pump(const Duration(milliseconds: 400));

    expect(events.scanned, isEmpty);
    expect(events.arrows, isEmpty);
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

  testWidgets('typing into a focused text field never triggers the shortcuts', (
    tester,
  ) async {
    final scanned = <String>[];
    final arrows = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeScanListener(
          onBarcodeScanned: scanned.add,
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

    expect(arrows, isEmpty);
  });
}
