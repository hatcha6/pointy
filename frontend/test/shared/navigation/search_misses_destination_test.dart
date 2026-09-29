import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/command_palette/command_palette.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../fake_app_navigation.dart';

/// «عمليات بحث بلا نتائج» lists and acts on words only for someone the server
/// lets change products (catalog.change_product), so the drawer, the rail and
/// the command palette offer it to them and to nobody else.
void main() {
  const searchMisses = AppNavigationDestination.searchMisses;
  final l10n = lookupAppLocalizations(const Locale('ar'));

  test('is gated on changing products', () {
    expect(
      appNavigationDestinationCapability(searchMisses),
      AppCapability.changeProduct,
    );
    expect(
      FakeAppNavigation(
        currentUser: _manager,
      ).isDestinationAvailable(searchMisses),
      isTrue,
    );
    expect(
      FakeAppNavigation(
        currentUser: _clerk(),
      ).isDestinationAvailable(searchMisses),
      isFalse,
    );
    expect(
      FakeAppNavigation(
        currentUser: _clerk(extra: const {'catalog.change_product'}),
      ).isDestinationAvailable(searchMisses),
      isTrue,
    );
  });

  testWidgets('a manager\'s drawer lists it with the stock screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.catalog,
            navigation: FakeAppNavigation(currentUser: _manager),
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    expect(find.text(l10n.searchMissesDrawerLabel), findsOneWidget);
  });

  testWidgets('the command palette finds it by the words an owner types', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SizedBox.shrink()));
    final context = tester.element(find.byType(SizedBox));

    List<String> screens(PosUser user, String query) => [
      for (final item in NavigationCommandSource(
        FakeAppNavigation(currentUser: user),
      ).filter(context, query))
        item.id,
    ];

    // «نتايج» is how a till keyboard without hamza spells «نتائج».
    for (final query in const ['بلا نتائج', 'نتايج بحث', 'غير موجود']) {
      expect(screens(_manager, query), contains('screen-searchMisses'));
      expect(screens(_clerk(), query), isNot(contains('screen-searchMisses')));
    }
  });
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: PointyTheme.light(),
    home: home,
  );
}

const _manager = PosUser(
  id: 1,
  username: 'owner',
  role: UserRole.manager,
  isActive: true,
);

/// Someone who reads the catalogue but may not change it, plus [extra].
PosUser _clerk({Set<String> extra = const {}}) {
  return PosUser(
    id: 5,
    username: 'clerk',
    role: UserRole.inventoryClerk,
    isActive: true,
    permissions: {
      'catalog.view_product',
      'catalog.view_productcategory',
      'catalog.view_productvariant',
      ...extra,
    },
  );
}
