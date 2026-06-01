import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  testWidgets('PointyScaffold preserves drawer opening from app bar leading', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      child: PointyScaffold(
        drawer: const Drawer(child: Text('القائمة')),
        appBar: PointyAppBar(
          title: const Text('المنتجات'),
          leading: Builder(
            builder: (context) {
              return IconButton(
                tooltip: 'القائمة',
                onPressed: Scaffold.of(context).openDrawer,
                icon: const Icon(Icons.menu),
              );
            },
          ),
        ),
        body: const Text('المحتوى'),
      ),
    );

    expect(find.text('المحتوى'), findsOneWidget);

    await tester.tap(find.byTooltip('القائمة'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(Drawer), findsOneWidget);
  });

  testWidgets(
    'PointyAppBar supports high-focus style and stable loading slot',
    (tester) async {
      await _pumpShell(
        tester,
        child: const PointyScaffold(
          appBar: PointyAppBar(
            title: Text('نقطة البيع'),
            style: PointyAppBarStyle.highFocus,
            isLoading: true,
            actions: [Icon(Icons.sync)],
          ),
          body: SizedBox.shrink(),
        ),
      );

      final appBar = tester.widget<AppBar>(find.byType(AppBar));

      expect(appBar.backgroundColor, PointyColors.darkTopBar);
      expect(appBar.foregroundColor, PointyColors.surface);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.sync), findsOneWidget);
    },
  );

  testWidgets('PointyScaffold shows app navigation rail on desktop', (
    tester,
  ) async {
    var opened = '';

    await _pumpShell(
      tester,
      width: 1200,
      child: PointyScaffold(
        drawer: _navigationDrawer(
          onOpenPurchasing: () => opened = 'purchasing',
        ),
        appBar: AppBar(title: const Text('الصفحة')),
        body: const Text('المحتوى'),
      ),
    );

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byTooltip('لوحة التحكم'), findsOneWidget);
    expect(find.text('المحتوى'), findsOneWidget);

    await tester.tap(find.byTooltip('المشتريات'));
    expect(opened, 'purchasing');
  });

  testWidgets('AppNavigationDrawer keeps primary destinations ordered', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      height: 900,
      child: PointyScaffold(
        drawer: _navigationDrawer(),
        appBar: AppBar(
          leading: Builder(
            builder: (context) {
              return IconButton(
                tooltip: 'القائمة',
                onPressed: Scaffold.of(context).openDrawer,
                icon: const Icon(Icons.menu),
              );
            },
          ),
          title: const Text('الصفحة'),
        ),
        body: const Text('المحتوى'),
      ),
    );

    await tester.tap(find.byTooltip('القائمة'));
    await tester.pumpAndSettle();

    expect(_top(tester, 'لوحة التحكم'), lessThan(_top(tester, 'شاشة البيع')));
    expect(_top(tester, 'المنتجات'), lessThan(_top(tester, 'التصنيفات')));
    expect(_top(tester, 'التصنيفات'), lessThan(_top(tester, 'جلسات الدرج')));
  });
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required Widget child,
  double width = 390,
  double height = 800,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(textDirection: TextDirection.rtl, child: child),
    ),
  );
}

double _top(WidgetTester tester, String text) {
  return tester.getTopLeft(find.text(text).first).dy;
}

AppNavigationDrawer _navigationDrawer({VoidCallback? onOpenPurchasing}) {
  const currentUser = PosUser(
    id: 1,
    username: 'manager',
    displayName: 'مدير النظام',
    role: UserRole.manager,
    isActive: true,
  );

  return AppNavigationDrawer(
    selectedDestination: AppNavigationDestination.dashboard,
    currentUser: currentUser,
    capabilities: AuthorizationCapabilities.forUser(currentUser),
    onOpenDashboard: () {},
    onOpenPos: () {},
    onOpenPurchasing: onOpenPurchasing ?? () {},
    onOpenContacts: () {},
    onOpenCatalog: () {},
    onOpenCategories: () {},
    onOpenRegisterSessions: () {},
    onOpenDeviceSettings: () {},
    onOpenDiscounts: () {},
    onOpenReports: () {},
    onOpenUsers: () {},
    onOpenShopSettings: () {},
    onLogout: () {},
  );
}
