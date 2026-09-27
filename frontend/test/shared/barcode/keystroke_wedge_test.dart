import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';
import 'package:pointy_frontend/src/shared/barcode/keystroke_wedge.dart';

import '../../support/moamalat_receipt_links.dart';

/// Whatever the wedge typed, it must be exactly what a USB scanner would have
/// delivered: these tests put the scan through real listeners, real fields
/// and real shortcuts, never through a callback the test calls itself.
void main() {
  // The wedge's own clock only times a wait for a held modifier; a fixed one
  // keeps that wait from depending on how fast the machine runs the test.
  late DateTime now;
  late KeystrokeWedge wedge;

  setUp(() {
    now = DateTime(2026, 9, 26, 12);
    wedge = KeystrokeWedge(source: 'camera_wedge', clock: () => now);
  });
  tearDown(() => wedge.dispose());

  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: home)));
    await tester.pump();
  }

  testWidgets('a scan reaches a screen scan listener with nothing focused', (
    tester,
  ) async {
    final scanned = <String>[];
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: const SizedBox.expand(),
      ),
    );

    wedge.type('6291041500213');

    expect(scanned, ['6291041500213']);
    expect(
      HardwareKeyboard.instance.physicalKeysPressed,
      isEmpty,
      reason: 'every key the wedge pressed, it let go',
    );
  });

  testWidgets('a scan into a focused search field is caught as a scan and '
      'the field put back, as a USB scanner burst is', (tester) async {
    final scanned = <String>[];
    final search = TextEditingController(text: 'مياه');
    addTearDown(search.dispose);
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: TextField(controller: search, autofocus: true),
      ),
    );

    wedge.type('6291041500213');
    await tester.pump();

    expect(scanned, ['6291041500213']);
    expect(search.text, 'مياه');
  });

  testWidgets('a focused field with no scan listener is typed into and '
      'submitted, as a USB scanner would', (tester) async {
    final submitted = <String>[];
    final field = TextEditingController();
    addTearDown(field.dispose);
    await pumpApp(
      tester,
      TextField(controller: field, autofocus: true, onSubmitted: submitted.add),
    );

    wedge.type('INV-2026/0042');
    await tester.pump();

    expect(field.text, 'INV-2026/0042');
    expect(submitted, ['INV-2026/0042']);
  });

  testWidgets('a field marked as a scan target takes the raw scan even under '
      'a scan listener', (tester) async {
    final scanned = <String>[];
    final submitted = <String>[];
    final field = TextEditingController();
    addTearDown(field.dispose);
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: ScanWedgeTarget(
          child: TextField(
            controller: field,
            autofocus: true,
            onSubmitted: submitted.add,
          ),
        ),
      ),
    );

    wedge.type('SUP-88812');
    await tester.pump();

    expect(scanned, isEmpty);
    expect(field.text, 'SUP-88812');
    expect(submitted, ['SUP-88812']);
  });

  testWidgets('Enter in a multi-line field starts a new line and submits '
      'nothing', (tester) async {
    final submitted = <String>[];
    final field = TextEditingController();
    addTearDown(field.dispose);
    await pumpApp(
      tester,
      TextField(
        controller: field,
        autofocus: true,
        maxLines: 3,
        onSubmitted: submitted.add,
      ),
    );

    wedge.type('line');
    await tester.pump();

    expect(field.text, 'line\n');
    expect(submitted, isEmpty);
  });

  testWidgets('typing lands at the caret, over the selection, like a key '
      'press', (tester) async {
    final field = TextEditingController(text: 'AB-XX-CD')
      ..selection = const TextSelection(baseOffset: 3, extentOffset: 5);
    addTearDown(field.dispose);
    await pumpApp(tester, TextField(controller: field, autofocus: true));
    // Focusing a field may move its caret; put the selection back.
    field.selection = const TextSelection(baseOffset: 3, extentOffset: 5);
    await tester.pump();

    wedge.type('77');
    await tester.pump();

    expect(field.text, 'AB-77-CD');
  });

  testWidgets('a receipt link arrives character for character, whatever the '
      'keyboard layout', (tester) async {
    // The Moamalat slip is a URL full of Latin letters and %-escapes. A USB
    // scanner with the Arabic layout on types those letters as Arabic ones;
    // the wedge types characters, not key positions.
    final scanned = <String>[];
    final receipt = moamalatReceiptUrl(amount: 45);
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: const SizedBox.expand(),
      ),
    );

    wedge.type(receipt);
    wedge.type('طلبية رقم ٤٢');

    expect(scanned, [receipt, 'طلبية رقم ٤٢']);
  });

  testWidgets('control characters inside a code are not typed', (tester) async {
    // A line break would be an Enter that cuts one scan in two.
    final scanned = <String>[];
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: const SizedBox.expand(),
      ),
    );

    wedge.type('0104\n2601\t2345\u001d67');

    expect(scanned, ['01042601234567']);
  });

  testWidgets('a code of nothing but control characters presses nothing, '
      'not even Enter', (tester) async {
    var presses = 0;
    await pumpApp(
      tester,
      Center(
        child: ElevatedButton(
          autofocus: true,
          onPressed: () => presses += 1,
          child: const Text('checkout'),
        ),
      ),
    );

    wedge.type('\n\r');
    await tester.pump();
    expect(presses, 0);

    // Whereas a real code does end in Enter, which a focused button hears —
    // exactly as it would hear a USB scanner's.
    wedge.type('123');
    await tester.pump();
    expect(presses, 1);
  });

  testWidgets('a key claimed by a focus handler never reaches the field', (
    tester,
  ) async {
    // The cart's quantity keys work this way: a pane handles the digit, so
    // the platform never types it anywhere.
    final seen = <String>[];
    final field = TextEditingController();
    addTearDown(field.dispose);
    await pumpApp(
      tester,
      Focus(
        onKeyEvent: (node, event) {
          final character = event.character;
          if (event is KeyDownEvent && character != null) seen.add(character);
          final isDigit =
              character != null && RegExp(r'^[0-9]$').hasMatch(character);
          return isDigit ? KeyEventResult.handled : KeyEventResult.ignored;
        },
        child: TextField(controller: field, autofocus: true),
      ),
    );

    wedge.type('a1b2');
    await tester.pump();

    expect(seen, ['a', '1', 'b', '2']);
    expect(field.text, 'ab');
  });

  testWidgets('a read-only field takes nothing', (tester) async {
    final submitted = <String>[];
    final field = TextEditingController(text: 'fixed');
    addTearDown(field.dispose);
    await pumpApp(
      tester,
      TextField(
        controller: field,
        autofocus: true,
        readOnly: true,
        onSubmitted: submitted.add,
      ),
    );

    wedge.type('999');
    await tester.pump();

    expect(field.text, 'fixed');
    expect(submitted, isEmpty);
  });

  testWidgets('a covered screen does not hear the scan; the one on top does', (
    tester,
  ) async {
    // The payment sheet over the till: the receipt QR is for the sheet, and
    // the till behind it must not try to ring it up.
    final till = <String>[];
    final sheet = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeScanListener(
          onBarcodeScanned: till.add,
          child: const Scaffold(body: Text('till')),
        ),
        routes: {
          '/sheet': (_) => BarcodeScanListener(
            onBarcodeScanned: sheet.add,
            child: const Scaffold(body: Text('sheet')),
          ),
        },
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.pushNamed('/sheet'));
    await tester.pumpAndSettle();

    wedge.type('pay://receipt/9f2');

    expect(till, isEmpty);
    expect(sheet, ['pay://receipt/9f2']);
  });

  testWidgets('a screen that is busy drops the scan, as it drops a USB '
      "scanner's", (tester) async {
    final scanned = <String>[];
    final field = TextEditingController(text: '2');
    addTearDown(field.dispose);
    await pumpApp(
      tester,
      BarcodeScanListener(
        enabled: false,
        onBarcodeScanned: scanned.add,
        child: TextField(controller: field, autofocus: true),
      ),
    );

    wedge.type('6291041500213');
    await tester.pump();

    expect(scanned, isEmpty);
    expect(field.text, '2', reason: 'and nothing leaks into the field');
  });

  testWidgets('nothing is typed while another program has the keyboard', (
    tester,
  ) async {
    final scanned = <String>[];
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: const SizedBox.expand(),
      ),
    );
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    wedge.type('read-while-away');
    await tester.pump(const Duration(seconds: 2));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    expect(
      scanned,
      isEmpty,
      reason:
          'a USB scanner would have typed it into the other program; it '
          'does not turn up here later either',
    );

    wedge.type('read-while-here');
    expect(scanned, ['read-while-here']);
  });

  testWidgets('a held Ctrl holds the scan back until it is let go', (
    tester,
  ) async {
    // Typed over Ctrl, the keys would be shortcuts: Ctrl+Enter is checkout.
    final scanned = <String>[];
    var checkouts = 0;
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        onCommandEnter: () => checkouts += 1,
        child: const SizedBox.expand(),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    wedge.type('6291041500213');
    await tester.pump(const Duration(milliseconds: 200));
    expect(scanned, isEmpty);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(scanned, ['6291041500213']);
    expect(checkouts, 0);
  });

  testWidgets('a modifier held past the wedge patience drops the scan', (
    tester,
  ) async {
    final scanned = <String>[];
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: const SizedBox.expand(),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    wedge.type('6291041500213');
    for (var i = 0; i < 25; i++) {
      now = now.add(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(scanned, isEmpty);
  });

  testWidgets('typingSource names the wedge while its keys are handled, and '
      'nothing for a real key press', (tester) async {
    final sources = <String?>[];
    // Real key events arrive over simulated platform messages; a fixed clock
    // keeps them a burst however slowly the machine delivers them.
    final instant = DateTime(2026, 9, 26, 12);
    await pumpApp(
      tester,
      BarcodeScanListener(
        clock: () => instant,
        onBarcodeScanned: (_) => sources.add(KeystrokeWedge.typingSource),
        child: const SizedBox.expand(),
      ),
    );

    wedge.type('6291041500213');
    expect(sources, ['camera_wedge']);
    expect(KeystrokeWedge.typingSource, isNull);

    for (final key in [
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit9,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(sources, ['camera_wedge', null]);
  });

  testWidgets('a disposed wedge types nothing', (tester) async {
    final scanned = <String>[];
    await pumpApp(
      tester,
      BarcodeScanListener(
        onBarcodeScanned: scanned.add,
        child: const SizedBox.expand(),
      ),
    );

    wedge.dispose();
    wedge.type('6291041500213');

    expect(scanned, isEmpty);
  });
}
