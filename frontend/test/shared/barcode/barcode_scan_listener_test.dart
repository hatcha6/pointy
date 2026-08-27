import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';

/// Deterministic time source: sendKeyEvent runs in real time, so burst-vs-
/// human timing must be driven explicitly, not with pump() (which advances
/// only the fake test clock, never DateTime.now()).
class _FakeClock {
  DateTime now = DateTime(2026, 1, 1, 12);

  void advance(Duration duration) => now = now.add(duration);
}

void main() {
  Future<
    ({
      List<String> scanned,
      List<LogicalKeyboardKey> arrows,
      List<LogicalKeyboardKey> functionKeys,
      List<LogicalKeyboardKey> pageKeys,
      List<int> commandEnters,
      _FakeClock clock,
    })
  >
  pumpListener(
    WidgetTester tester, {
    bool enabled = true,
    Widget child = const SizedBox.expand(),
  }) async {
    final scanned = <String>[];
    final arrows = <LogicalKeyboardKey>[];
    final functionKeys = <LogicalKeyboardKey>[];
    final pageKeys = <LogicalKeyboardKey>[];
    final commandEnters = <int>[];
    final clock = _FakeClock();
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeScanListener(
          enabled: enabled,
          onBarcodeScanned: scanned.add,
          onArrowKey: (key) {
            arrows.add(key);
            return true;
          },
          onFunctionKey: (key) {
            functionKeys.add(key);
            return true;
          },
          onPageKey: (key) {
            pageKeys.add(key);
            return true;
          },
          onCommandEnter: () => commandEnters.add(1),
          clock: () => clock.now,
          child: child,
        ),
      ),
    );
    await tester.pump();
    return (
      scanned: scanned,
      arrows: arrows,
      functionKeys: functionKeys,
      pageKeys: pageKeys,
      commandEnters: commandEnters,
      clock: clock,
    );
  }

  final digits12345678 = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
  ];

  // sendKeyEvent does not run the platform text-input pipeline, so characters
  // never land in a TextField on their own in tests. When [typeInto] is given,
  // mirror what the platform would do: the key event first (the listener sees
  // it and snapshots), then the character appears in the field.
  Future<void> sendBurst(
    WidgetTester tester,
    _FakeClock clock,
    List<LogicalKeyboardKey> keys, {
    Duration interKeyGap = const Duration(milliseconds: 20),
    bool terminate = true,
    TextEditingController? typeInto,
  }) async {
    for (final key in keys) {
      clock.advance(interKeyGap);
      await tester.sendKeyEvent(key);
      if (typeInto != null) {
        final text = typeInto.text + key.keyLabel;
        typeInto.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    }
    if (terminate) {
      clock.advance(interKeyGap);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    }
  }

  testWidgets('a scanner burst submits the barcode', (tester) async {
    final events = await pumpListener(tester);

    await sendBurst(tester, events.clock, digits12345678);
    await tester.pump();

    expect(events.scanned, ['12345678']);
  });

  testWidgets('typed digits never fire anything but a terminated scan — a '
      'scan can never signal a quantity', (tester) async {
    final events = await pumpListener(tester);

    // Digits typed at human pace, without a terminator, produce no callback:
    // there is no digit → quantity path a scanner could ever trip.
    events.clock.advance(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    events.clock.advance(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.pump();

    expect(events.scanned, isEmpty);
    expect(events.arrows, isEmpty);
  });

  testWidgets('an Enter long after the burst never submits the stale buffer', (
    tester,
  ) async {
    final events = await pumpListener(tester);

    await sendBurst(tester, events.clock, digits12345678, terminate: false);
    events.clock.advance(const Duration(seconds: 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(events.scanned, isEmpty);
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

  testWidgets('arrows and slow typing inside a focused text field never '
      'trigger the shortcuts', (tester) async {
    final events = await pumpListener(
      tester,
      child: const Material(child: TextField(autofocus: true)),
    );

    events.clock.advance(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit7);
    events.clock.advance(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(events.arrows, isEmpty);
    expect(events.scanned, isEmpty);
  });

  testWidgets('a burst into a focused text field is intercepted: the field is '
      'restored, the Enter is consumed, and the scan fires', (tester) async {
    final controller = TextEditingController(text: '3');
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final events = await pumpListener(
      tester,
      child: Material(
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: submitted.add,
        ),
      ),
    );
    // Park the caret at the end, as a cashier who just typed "3" would have it.
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );

    await sendBurst(tester, events.clock, digits12345678, typeInto: controller);
    await tester.pump();

    expect(events.scanned, ['12345678']);
    expect(controller.text, '3', reason: 'the burst must be rolled back');
    expect(submitted, isEmpty, reason: 'the terminator must be consumed');
  });

  testWidgets('slow typing into a focused text field stays in the field and '
      'Enter submits it normally', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final events = await pumpListener(
      tester,
      child: Material(
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: submitted.add,
        ),
      ),
    );

    for (final key in [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
    ]) {
      await sendBurst(
        tester,
        events.clock,
        [key],
        interKeyGap: const Duration(milliseconds: 300),
        terminate: false,
        typeInto: controller,
      );
    }
    events.clock.advance(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, '12345', reason: 'human typing is never undone');
    expect(events.scanned, isEmpty);
  });

  testWidgets('while disabled, a burst into a text field is still rolled back '
      'and its terminator consumed — the payload is dropped, not leaked', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final events = await pumpListener(
      tester,
      enabled: false,
      child: Material(
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: submitted.add,
        ),
      ),
    );

    await sendBurst(tester, events.clock, digits12345678, typeInto: controller);
    await tester.pump();

    expect(events.scanned, isEmpty, reason: 'disabled drops the payload');
    expect(controller.text, isEmpty, reason: 'the burst must not leak');
    expect(submitted, isEmpty);
  });

  testWidgets(
    'a ScanWedgeTarget field receives the raw wedge input untouched',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final submitted = <String>[];
      final events = await pumpListener(
        tester,
        child: Material(
          child: ScanWedgeTarget(
            child: TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: submitted.add,
            ),
          ),
        ),
      );

      await sendBurst(
        tester,
        events.clock,
        digits12345678,
        typeInto: controller,
      );
      await tester.pump();

      expect(events.scanned, isEmpty);
      expect(
        controller.text,
        '12345678',
        reason: 'exempt fields keep the wedge input',
      );
    },
  );

  testWidgets('function keys fire globally — with or without a focused text '
      'field', (tester) async {
    final events = await pumpListener(
      tester,
      child: const Material(child: TextField(autofocus: true)),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    events.clock.advance(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();

    expect(events.functionKeys, [LogicalKeyboardKey.f1, LogicalKeyboardKey.f2]);
    expect(events.scanned, isEmpty);
  });

  testWidgets('page keys fire globally — even with a focused text field', (
    tester,
  ) async {
    final events = await pumpListener(
      tester,
      child: const Material(child: TextField(autofocus: true)),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    events.clock.advance(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump();

    expect(events.pageKeys, [
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.pageUp,
    ]);
    expect(events.scanned, isEmpty);
  });

  testWidgets('a function key ends a scan burst in flight', (tester) async {
    final events = await pumpListener(tester);

    await sendBurst(tester, events.clock, digits12345678, terminate: false);
    events.clock.advance(const Duration(milliseconds: 20));
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    events.clock.advance(const Duration(milliseconds: 20));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(events.functionKeys, [LogicalKeyboardKey.f4]);
    expect(
      events.scanned,
      isEmpty,
      reason: 'the buffer died with the function key',
    );
  });

  testWidgets('Ctrl+Enter fires the checkout chord instead of a scan submit', (
    tester,
  ) async {
    final events = await pumpListener(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(events.commandEnters, hasLength(1));
    expect(events.scanned, isEmpty);
  });

  testWidgets('while disabled, function keys and the checkout chord are '
      'dropped', (tester) async {
    final events = await pumpListener(tester, enabled: false);

    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(events.functionKeys, isEmpty);
    expect(events.commandEnters, isEmpty);
  });
}
