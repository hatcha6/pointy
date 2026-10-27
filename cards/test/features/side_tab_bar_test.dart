import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/features/account/account_page.dart';
import 'package:pointy_cards/src/features/search/search_page.dart';
import 'package:pointy_cards/src/features/shell/cards_tab_bar.dart';

void main() {
  test('only a one-sided system column puts the tabs at the side', () {
    // The iPhone Duo: the status bar runs down the right edge.
    expect(
      CardsTabBar.side(const EdgeInsets.only(right: 100, bottom: 20)),
      AxisDirection.right,
    );
    // Split View with the app on the left of the inner display.
    expect(
      CardsTabBar.side(const EdgeInsets.only(left: 100)),
      AxisDirection.left,
    );
    // A phone on its side: a notch inset on both sides.
    expect(
      CardsTabBar.side(const EdgeInsets.only(left: 59, right: 59)),
      isNull,
    );
    // A phone upright.
    expect(
      CardsTabBar.side(const EdgeInsets.only(top: 59, bottom: 34)),
      isNull,
    );
  });

  testWidgets('on the iPhone Duo the tabs stand in the right-hand column', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(466 * 3, 678 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(right: 100 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    final bar = tester.getRect(find.byType(CardsSideTabBar));
    // Inside the column, below the status bar at its top.
    expect(bar.left, greaterThanOrEqualTo(466 - 100));
    expect(bar.center.dy, greaterThan(678 / 2));

    await tester.tap(find.byTooltip('حسابي'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountPage), findsOneWidget);
  });

  testWidgets('the side search button opens the search page, ready to type', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(466 * 3, 678 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(right: 100 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('حسابي'));
    await tester.pumpAndSettle();

    // Under the tabs, standing apart.
    final tabs = tester.getRect(find.byTooltip('حسابي'));
    final search = tester.getRect(find.byIcon(Icons.search_rounded).last);
    expect(search.top, greaterThan(tabs.bottom));

    await tester.tap(find.byIcon(Icons.search_rounded).last);
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(TextField),
      ),
    );
    expect(field.autofocus, isTrue);
    // Before anything is typed, the categories to browse.
    expect(find.text('تصفّح الأقسام'), findsOneWidget);

    // Typing finds brands; a category picked closes the page onto it.
    await tester.enterText(find.byType(TextField).last, 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('تصفّح الأقسام'), findsNothing);
    await tester.enterText(find.byType(TextField).last, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsNothing);
    expect(find.byType(AccountPage), findsNothing);
  });
}
