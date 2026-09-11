import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/companion/companion_scan_listener.dart';

import '../../support/fake_companion_bridge.dart';

void main() {
  testWidgets('a phone scan reaches the screen on top', (tester) async {
    final bridge = FakeCompanionBridge();
    addTearDown(bridge.dispose);
    final scanned = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: CompanionScanListener(
          bridge: bridge,
          onScan: scanned.add,
          child: const SizedBox.expand(),
        ),
      ),
    );

    bridge.emitScan('6291041500213');
    await tester.pumpAndSettle();

    expect(scanned, ['6291041500213']);
  });

  testWidgets('a phone scan stops at the screen a dialog is covering', (
    tester,
  ) async {
    final bridge = FakeCompanionBridge();
    addTearDown(bridge.dispose);
    final scanned = <String>[];
    late BuildContext screenContext;

    await tester.pumpWidget(
      MaterialApp(
        home: CompanionScanListener(
          bridge: bridge,
          onScan: scanned.add,
          child: Builder(
            builder: (context) {
              screenContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    // A phone scan is broadcast to every listener at once, so without route
    // gating the screen under an open payment sheet would still try to make a
    // product out of the receipt QR scanned into that sheet.
    unawaited(
      showDialog<void>(
        context: screenContext,
        builder: (context) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();

    bridge.emitScan('6291041500213');
    await tester.pumpAndSettle();

    expect(scanned, isEmpty);

    Navigator.of(screenContext).pop();
    await tester.pumpAndSettle();

    bridge.emitScan('6291041500213');
    await tester.pumpAndSettle();

    expect(scanned, ['6291041500213'], reason: 'the screen hears again');
  });

  testWidgets('no bridge means nothing happens at all', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CompanionScanListener(
          bridge: null,
          onScan: (_) => fail('no phone is paired'),
          child: const SizedBox.expand(),
        ),
      ),
    );

    await tester.pumpAndSettle();
  });
}
