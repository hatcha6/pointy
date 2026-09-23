import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

const _message = 'تم الحفظ';

void main() {
  final snackBars = <String, SnackBar Function()>{
    'a plain snackbar': () => const SnackBar(content: Text(_message)),
    // Flutter keeps these up until somebody taps the action.
    'a snackbar with an action': () => SnackBar(
      content: const Text(_message),
      action: SnackBarAction(label: 'تراجع', onPressed: () {}),
    ),
    'a snackbar that asked for ten seconds': () => const SnackBar(
      content: Text(_message),
      duration: Duration(seconds: 10),
    ),
  };

  for (final MapEntry(key: name, value: build) in snackBars.entries) {
    testWidgets('$name closes after three seconds', (tester) async {
      await _show(tester, build());

      await tester.pump(const Duration(milliseconds: 2800));
      expect(find.text(_message), findsOneWidget);

      // Flutter's own default would still be showing it at 3.1s.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text(_message), findsNothing);
    });
  }

  testWidgets('keeps everything else the screen built', (tester) async {
    var undone = false;
    await _show(
      tester,
      SnackBar(
        content: const Text(_message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.fixed,
        showCloseIcon: true,
        action: SnackBarAction(label: 'تراجع', onPressed: () => undone = true),
      ),
    );

    final shown = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(shown.duration, PointyScaffoldMessenger.snackBarDuration);
    expect(shown.persist, isFalse);
    expect(shown.backgroundColor, Colors.red);
    expect(shown.behavior, SnackBarBehavior.fixed);
    expect(shown.showCloseIcon, isTrue);

    await tester.tap(find.text('تراجع'));
    expect(undone, isTrue);
  });
}

/// Mounted the way the app mounts it: inside [MaterialApp.builder], nested
/// under the messenger [MaterialApp] makes for itself.
Future<void> _show(WidgetTester tester, SnackBar snackBar) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => PointyScaffoldMessenger(child: child!),
      home: const Scaffold(body: SizedBox.shrink()),
    ),
  );
  // Shown directly rather than from a tapped button: a button's ink ripple
  // keeps the settle below running after the snackbar's timer has started.
  ScaffoldMessenger.of(
    tester.element(find.byType(Scaffold)),
  ).showSnackBar(snackBar);
  // Settled is the moment the snackbar has slid in and its timer starts.
  await tester.pumpAndSettle();
}
