import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../fake_app_navigation.dart';

/// The navigation list is one list with one place in it, however many screens
/// draw it.
///
/// Each screen builds its own drawer/rail inside its own route, and the routes
/// left underneath stay alive holding a scroll position each — so "the same
/// place on every screen" is not something the widget tree gives for free.
/// These are the journeys that used to break it.
void main() {
  group('navigation rail scroll offset', () {
    testWidgets('a pushed screen opens the rail where it was left', (
      tester,
    ) async {
      final app = await _pumpShell(tester);

      await _dragRail(tester, -150);
      final left = _railOffset(tester);
      expect(left, greaterThan(0));

      await app.push(tester, 'الثانية');

      expect(_railOffset(tester), left);
    });

    testWidgets('going back shows where the rail was last left, not where '
        'this screen left it', (tester) async {
      final app = await _pumpShell(tester);

      await _dragRail(tester, -100);
      await app.push(tester, 'الثانية');
      await _dragRail(tester, -120);
      final left = _railOffset(tester);

      await app.pop(tester);

      // The screen underneath was alive the whole time with a rail of its own,
      // scrolled to where it was when it was last on show. Before the shared
      // store it put that stale offset back on screen.
      expect(_railOffset(tester), left);
    });

    testWidgets('popping to the first route — what choosing the dashboard '
        'does — shows where the rail was last left', (tester) async {
      final app = await _pumpShell(tester);

      await app.push(tester, 'الثانية');
      await _dragRail(tester, -140);
      final left = _railOffset(tester);

      await app.popToFirst(tester);

      expect(find.text('body-الأولى'), findsOneWidget);
      expect(_railOffset(tester), left);
    });

    testWidgets('a screen that replaces another opens the rail where it was '
        'left', (tester) async {
      final app = await _pumpShell(tester);

      await app.push(tester, 'الثانية');
      await _dragRail(tester, -130);
      final left = _railOffset(tester);

      await app.pushReplacement(tester, 'الثالثة');

      expect(find.text('body-الثالثة'), findsOneWidget);
      expect(_railOffset(tester), left);
    });

    testWidgets('the rail does not hand its scrolling to the screen it sits '
        'beside', (tester) async {
      final app = await _pumpShell(tester);

      await _dragRail(tester, -150);

      // The rail lives in the Scaffold's body, so without a stop its scroll
      // notifications reach the screen's app bar, which treats them as the
      // content scrolling under it.
      expect(app.bodyScrollNotifications, isEmpty);
    });

    testWidgets('collapsing the rail does not move the expanded rail', (
      tester,
    ) async {
      final app = await _pumpShell(tester);

      await _dragRail(tester, -150);
      final expanded = _railOffset(tester);

      await tester.tap(find.byTooltip('طي التنقل'));
      await tester.pumpAndSettle();
      // The collapsed rail is a denser list: it starts at the top rather than
      // inheriting a number that means somewhere else.
      expect(_railOffset(tester), 0);

      await app.push(tester, 'الثانية');
      expect(_railOffset(tester), 0);

      await tester.tap(find.byTooltip('توسيع التنقل'));
      await tester.pumpAndSettle();
      expect(_railOffset(tester), expanded);
    });

    testWidgets('a screen that cannot reach the offset does not cut it down '
        'for the ones that can', (tester) async {
      // A tall app bar leaves the rail a short viewport, so this screen can
      // scroll it further than a screen with a plain app bar can.
      final app = await _pumpShell(tester, appBarBottomHeight: 260);

      await _dragRail(tester, -4000);
      final left = _railOffset(tester);

      await app.push(tester, 'الثانية');
      final onRoomier = _railOffset(tester);
      // It sits at its own bottom, as close to [left] as it can get.
      expect(onRoomier, lessThan(left));

      await app.pop(tester);

      expect(_railOffset(tester), left);
    });
  });

  group('navigation drawer scroll offset', () {
    testWidgets('the drawer opens where it was left on the screen before', (
      tester,
    ) async {
      final app = await _pumpShell(tester, width: 600);

      await tester.tap(find.byTooltip('فتح القائمة'));
      await tester.pumpAndSettle();
      await _dragDrawer(tester, -120);
      final left = _drawerOffset(tester);
      expect(left, greaterThan(0));

      Navigator.of(tester.element(find.byType(PointyNavigationSurface))).pop();
      await tester.pumpAndSettle();
      await app.push(tester, 'الثانية');
      await tester.tap(find.byTooltip('فتح القائمة'));
      await tester.pumpAndSettle();

      expect(_drawerOffset(tester), left);
    });
  });

  group('navigation coverage', () {
    test('every top-level destination renders the navigation', () {
      // A destination the rail can reach but that draws no rail of its own is
      // a dead end: the navigation vanishes on arrival and the only way on is
      // the back button. The screens are found by the destination they mark as
      // selected, which is also what puts the highlight on the right tile.
      final rendered = _destinationsWithNavigationSurface();
      final missing = AppNavigationDestination.values
          .where((destination) => !rendered.contains(destination.name))
          .map((destination) => destination.name)
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'these destinations are reachable from the drawer/rail but no '
            'screen passes them to an AppNavigationDrawer, so arriving there '
            'loses the navigation: ${missing.join(', ')}',
      );
    });
  });
}

Set<String> _destinationsWithNavigationSurface() {
  final pattern = RegExp(
    r'selectedDestination:\s*AppNavigationDestination\.([a-zA-Z0-9_]+)',
  );
  final rendered = <String>{};
  for (final entity in Directory('lib/src').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    for (final match in pattern.allMatches(entity.readAsStringSync())) {
      rendered.add(match.group(1)!);
    }
  }
  return rendered;
}

const _user = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير النظام',
  role: UserRole.manager,
  isActive: true,
);

Finder _railList() {
  return find
      .descendant(
        of: find.byType(PointyNavigationRailSurface),
        matching: find.byType(Scrollable),
      )
      .first;
}

Finder _drawerList() {
  return find
      .descendant(
        of: find.byType(PointyNavigationSurface),
        matching: find.byType(Scrollable),
      )
      .first;
}

double _railOffset(WidgetTester tester) =>
    tester.state<ScrollableState>(_railList()).position.pixels;

double _drawerOffset(WidgetTester tester) =>
    tester.state<ScrollableState>(_drawerList()).position.pixels;

Future<void> _dragRail(WidgetTester tester, double dy) async {
  await tester.drag(_railList(), Offset(0, dy));
  await tester.pumpAndSettle();
}

Future<void> _dragDrawer(WidgetTester tester, double dy) async {
  await tester.drag(_drawerList(), Offset(0, dy));
  await tester.pumpAndSettle();
}

/// A shell with a real [Navigator] under an app-level rail scope, which is the
/// only arrangement in which the navigation's scroll offset means anything:
/// screens replace each other as routes and the ones underneath stay alive.
class _ShellHarness {
  _ShellHarness(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  final List<ScrollNotification> bodyScrollNotifications =
      <ScrollNotification>[];

  Future<void> push(
    WidgetTester tester,
    String title, {
    double appBarBottomHeight = 0,
  }) async {
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => _screen(
          this,
          title,
          AppNavigationDestination.invoices,
          appBarBottomHeight: appBarBottomHeight,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pushReplacement(WidgetTester tester, String title) async {
    navigatorKey.currentState!.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => _screen(this, title, AppNavigationDestination.reports),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pop(WidgetTester tester) async {
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  }

  Future<void> popToFirst(WidgetTester tester) async {
    navigatorKey.currentState!.popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
  }
}

Widget _screen(
  _ShellHarness harness,
  String title,
  AppNavigationDestination destination, {
  double appBarBottomHeight = 0,
}) {
  return NotificationListener<ScrollNotification>(
    onNotification: (notification) {
      harness.bodyScrollNotifications.add(notification);
      return false;
    },
    child: PointyScaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: destination,
        navigation: FakeAppNavigation(currentUser: _user),
      ),
      appBar: PointyAppBar(
        leading: const PointyNavigationMenuButton(),
        title: Text(title),
        bottom: appBarBottomHeight == 0
            ? null
            : PreferredSize(
                preferredSize: Size.fromHeight(appBarBottomHeight),
                child: SizedBox(height: appBarBottomHeight),
              ),
      ),
      body: Text('body-$title'),
    ),
  );
}

Future<_ShellHarness> _pumpShell(
  WidgetTester tester, {
  double width = 1400,
  double height = 700,
  double appBarBottomHeight = 0,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final controller = PointyNavigationRailController();
  addTearDown(controller.dispose);
  final navigatorKey = GlobalKey<NavigatorState>();
  final harness = _ShellHarness(navigatorKey);

  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: controller,
        navigationScrollStore: PointyNavigationScrollStore(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: _screen(
        harness,
        'الأولى',
        AppNavigationDestination.dashboard,
        appBarBottomHeight: appBarBottomHeight,
      ),
    ),
  );
  await tester.pumpAndSettle();
  harness.bodyScrollNotifications.clear();
  return harness;
}
