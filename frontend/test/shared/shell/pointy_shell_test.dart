import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  testWidgets(
    'PointyScaffold opens compact drawer from navigation menu button',
    (tester) async {
      await _pumpShell(
        tester,
        child: PointyScaffold(
          drawer: const Drawer(child: Text('القائمة')),
          appBar: PointyAppBar(
            title: const Text('المنتجات'),
            leading: const PointyNavigationMenuButton(),
          ),
          body: const Text('المحتوى'),
        ),
      );

      expect(find.text('المحتوى'), findsOneWidget);

      await tester.tap(find.byTooltip('فتح القائمة'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(Drawer), findsOneWidget);
    },
  );

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
      height: 1600,
      child: PointyScaffold(
        drawer: _navigationDrawer(
          onOpenPurchasing: () => opened = 'purchasing',
        ),
        appBar: AppBar(title: const Text('الصفحة')),
        body: const Text('المحتوى'),
      ),
    );

    expect(find.byType(PointyNavigationRailSurface), findsOneWidget);
    expect(find.byType(Scrollbar), findsNothing);
    expect(find.text('لوحة التحكم'), findsOneWidget);
    expect(find.text('المحتوى'), findsOneWidget);

    // Destinations are always visible under their section header, so reaching
    // one is a single tap — no expand step.
    await tester.tap(find.text('المشتريات'));
    expect(opened, 'purchasing');
  });

  testWidgets(
    'PointyScaffold toggles desktop navigation rail instead of drawer',
    (tester) async {
      await _pumpShell(
        tester,
        width: 1200,
        child: PointyScaffold(
          drawer: _navigationDrawer(),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: const Text('الصفحة'),
          ),
          body: const Text('المحتوى'),
        ),
      );

      expect(find.byType(Drawer), findsNothing);
      expect(
        tester
            .widget<PointyNavigationRailSurface>(
              find.byType(PointyNavigationRailSurface),
            )
            .extended,
        isTrue,
      );

      await tester.tap(find.byTooltip('طي التنقل'));
      await tester.pumpAndSettle();

      expect(find.byType(Drawer), findsNothing);
      expect(
        tester
            .widget<PointyNavigationRailSurface>(
              find.byType(PointyNavigationRailSurface),
            )
            .extended,
        isFalse,
      );

      await tester.tap(find.byTooltip('توسيع التنقل'));
      await tester.pumpAndSettle();

      expect(find.byType(Drawer), findsNothing);
      expect(
        tester
            .widget<PointyNavigationRailSurface>(
              find.byType(PointyNavigationRailSurface),
            )
            .extended,
        isTrue,
      );
    },
  );

  testWidgets('PointyScaffold keeps desktop rail state across screens', (
    tester,
  ) async {
    final controller = PointyNavigationRailController();
    addTearDown(controller.dispose);
    var showFirstScreen = true;

    await _pumpShell(
      tester,
      width: 1200,
      child: PointyNavigationRailScope(
        isActive: false,
        controller: controller,
        child: StatefulBuilder(
          builder: (context, setState) {
            return PointyScaffold(
              drawer: _navigationDrawer(),
              appBar: AppBar(
                leading: const PointyNavigationMenuButton(),
                title: Text(showFirstScreen ? 'الأولى' : 'الثانية'),
              ),
              body: TextButton(
                onPressed: () {
                  setState(() {
                    showFirstScreen = !showFirstScreen;
                  });
                },
                child: const Text('تبديل الشاشة'),
              ),
            );
          },
        ),
      ),
    );

    expect(
      tester
          .widget<PointyNavigationRailSurface>(
            find.byType(PointyNavigationRailSurface),
          )
          .extended,
      isTrue,
    );

    await tester.tap(find.byTooltip('طي التنقل'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PointyNavigationRailSurface>(
            find.byType(PointyNavigationRailSurface),
          )
          .extended,
      isFalse,
    );

    await tester.tap(find.text('تبديل الشاشة'));
    await tester.pumpAndSettle();

    expect(find.text('الثانية'), findsOneWidget);
    expect(
      tester
          .widget<PointyNavigationRailSurface>(
            find.byType(PointyNavigationRailSurface),
          )
          .extended,
      isFalse,
    );
  });

  testWidgets('AppNavigationDrawer keeps sections and destinations ordered', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      height: 1600,
      child: PointyScaffold(
        drawer: _navigationDrawer(),
        appBar: AppBar(
          leading: const PointyNavigationMenuButton(),
          title: const Text('الصفحة'),
        ),
        body: const Text('المحتوى'),
      ),
    );

    await tester.tap(find.byTooltip('فتح القائمة'));
    await tester.pumpAndSettle();

    // Section headers stay ordered top-to-bottom...
    expect(_top(tester, 'الرئيسية'), lessThan(_top(tester, 'المبيعات')));
    expect(
      _top(tester, 'المبيعات'),
      lessThan(_top(tester, 'المخزون والمشتريات')),
    );

    // ...and every destination is rendered (no expand needed), in order
    // beneath its header.
    expect(_top(tester, 'لوحة التحكم'), lessThan(_top(tester, 'شاشة البيع')));
    expect(_top(tester, 'جلسات الدرج'), lessThan(_top(tester, 'الخصومات')));
    expect(_top(tester, 'المنتجات'), lessThan(_top(tester, 'التصنيفات')));
    expect(_top(tester, 'التصنيفات'), lessThan(_top(tester, 'المشتريات')));
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
    navigation: _FakeAppNavigation(
      currentUser: currentUser,
      capabilities: AuthorizationCapabilities.forUser(currentUser),
      onNavigate: (destination) {
        if (destination == AppNavigationDestination.purchasing) {
          onOpenPurchasing?.call();
        }
      },
    ),
  );
}

class _FakeAppNavigation implements AppNavigation {
  const _FakeAppNavigation({
    required this.currentUser,
    required this.capabilities,
    this.onNavigate,
  });

  @override
  final PosUser currentUser;

  @override
  final AuthorizationCapabilities capabilities;

  final void Function(AppNavigationDestination destination)? onNavigate;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {
    onNavigate?.call(destination);
  }

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}
