import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_screen_tracker.dart';

/// The bug these cover: screen attribution used to be a side effect of `build`,
/// so it was set on the way into a screen and never on the way back out. A
/// cashier who opened an invoice and returned to the POS kept selling under the
/// name `invoice_details`, and every barcode scan after that was filed there.
void main() {
  late List<String?> screens;
  late List<String> entries;
  late AnalyticsRouteObserver observer;

  setUp(() {
    screens = [];
    entries = [];
    observer = AnalyticsRouteObserver();
  });

  Widget tracked(String name, {Widget? child}) {
    return TrackedScreen(
      name: name,
      onEnter: (screen, entry) {
        screens.add(screen);
        entries.add('$screen:${entry.name}');
      },
      child: child ?? Scaffold(body: Text(name)),
    );
  }

  Future<void> pumpApp(WidgetTester tester, Widget home) {
    return tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        // No engine: onEnter is the observable side of the same call, and it
        // keeps this test independent of queue/flush behaviour.
        home: AnalyticsScreenScope(
          analyticsEngine: null,
          routeObserver: observer,
          child: home,
        ),
      ),
    );
  }

  testWidgets('returning from a pushed screen restores the screen below', (
    tester,
  ) async {
    late BuildContext posContext;
    await pumpApp(
      tester,
      tracked(
        'pos',
        child: Builder(
          builder: (context) {
            posContext = context;
            return const Scaffold(body: Text('pos'));
          },
        ),
      ),
    );
    expect(screens, ['pos']);

    // The cashier opens an invoice...
    unawaited(
      Navigator.of(posContext).push(
        MaterialPageRoute<void>(builder: (_) => tracked('invoice_details')),
      ),
    );
    await tester.pumpAndSettle();
    expect(screens.last, 'invoice_details');

    // ...and closes it. This is the step that used to be missing.
    Navigator.of(posContext).pop();
    await tester.pumpAndSettle();
    expect(screens.last, 'pos');
    expect(entries.last, 'pos:returned');
  });

  testWidgets('a rebuild is not a navigation', (tester) async {
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);

    await pumpApp(
      tester,
      ValueListenableBuilder<int>(
        valueListenable: rebuild,
        builder: (context, value, _) =>
            tracked('pos', child: Scaffold(body: Text('$value'))),
      ),
    );
    expect(screens, ['pos']);

    // The home screen is built directly by AuthenticatedHome.build, so it
    // rebuilds for reasons that have nothing to do with where the user is.
    // Those rebuilds used to re-assert the screen name — which is how a user
    // standing on a pushed route got yanked back to 'pos'.
    rebuild.value = 1;
    await tester.pump();
    rebuild.value = 2;
    await tester.pump();
    expect(screens, ['pos']);
  });

  testWidgets('a rebuild underneath cannot steal the current screen', (
    tester,
  ) async {
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);
    late BuildContext homeContext;

    await pumpApp(
      tester,
      ValueListenableBuilder<int>(
        valueListenable: rebuild,
        builder: (context, value, _) => tracked(
          'pos',
          child: Builder(
            builder: (context) {
              homeContext = context;
              return Scaffold(body: Text('$value'));
            },
          ),
        ),
      ),
    );

    unawaited(
      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(builder: (_) => tracked('invoice_details')),
      ),
    );
    await tester.pumpAndSettle();
    expect(screens.last, 'invoice_details');

    rebuild.value = 1;
    await tester.pump();
    expect(screens.last, 'invoice_details');
  });

  testWidgets('swapping screens inside one route still tracks', (tester) async {
    // The auth screens are not separate routes — they swap inside the first
    // one — so there is no push to observe and mounting is the only signal.
    await pumpApp(tester, tracked('login'));
    expect(screens, ['login']);

    await pumpApp(tester, tracked('authenticated'));
    expect(screens, ['login', 'authenticated']);
  });

  testWidgets('without a scope it still reports, and never throws', (
    tester,
  ) async {
    // A missing scope costs the pop-restore, but must not silently swallow the
    // caller's own view events or break a screen that renders in a test
    // harness with no analytics wired up.
    await tester.pumpWidget(MaterialApp(home: tracked('pos')));
    expect(screens, ['pos']);
    expect(find.text('pos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the innermost tracker on a route wins', (tester) async {
    await pumpApp(tester, tracked('authenticated', child: tracked('pos')));
    // Both fire, but the specific one is applied last and so is what sticks.
    expect(screens, ['authenticated', 'pos']);
  });
}

void unawaited(Future<void> future) {}
