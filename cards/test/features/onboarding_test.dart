import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/settings/app_settings.dart';
import 'package:pointy_cards/src/dependencies.dart';
import 'package:pointy_cards/src/features/links/cards_link.dart';
import 'package:pointy_cards/src/features/links/link_inbox.dart';
import 'package:pointy_cards/src/features/onboarding/onboarding_page.dart';
import 'package:pointy_cards/src/features/splash/splash_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Future<void> phone(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// A first run: settings that are stored, and nothing stored yet.
Future<CardsDependencies> firstRun({
  bool signedIn = false,
  LinkInbox? links,
}) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final dependencies = fixtureDependencies(signedIn: signedIn, links: links);
  final settings = AppSettings(preferences: SharedPreferencesAsync());
  await settings.load();
  return CardsDependencies(
    config: dependencies.config,
    auth: dependencies.auth,
    catalog: dependencies.catalog,
    orders: dependencies.orders,
    vault: dependencies.vault,
    lock: dependencies.lock,
    settings: settings,
    links: dependencies.links,
  );
}

void main() {
  testWidgets('a first run walks three steps, then the shelf, once', (
    tester,
  ) async {
    await phone(tester);
    final dependencies = await firstRun();
    await tester.pumpWidget(CardsApp(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingPage), findsOneWidget);
    expect(find.text('كل كروتك في مكان واحد'), findsOneWidget);
    expect(find.bySemanticsLabel('الخطوة 1 من 3'), findsOneWidget);

    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(find.text('ادفع، ويصلك الرقم فوراً'), findsOneWidget);

    // Swiping works as well as the button (right to left: the next step is
    // to the left).
    await tester.drag(find.byType(PageView), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('كروتك محفوظة بأمان'), findsOneWidget);
    expect(find.text('تخطَّ'), findsOneWidget); // faded, not tappable
    await tester.tap(find.text('ابدأ الآن'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingPage), findsNothing);
    expect(find.text('ليبيانا'), findsWidgets);
    expect(dependencies.settings.onboarded, isTrue);

    // Kept: the next start goes straight to the shelf.
    final again = AppSettings(preferences: SharedPreferencesAsync());
    await again.load();
    expect(again.onboarded, isTrue);
  });

  testWidgets('the opening hands its tile to the first step', (tester) async {
    await phone(tester);
    final dependencies = await firstRun();
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        splash: const SplashOpening(SplashRun.quick),
      ),
    );
    await tester.pump();
    // While the opening plays, the first picture waits for the tile.
    final waiting = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byType(CustomPaint).at(1),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(waiting.opacity, 0);
    // The tile flies, lands, and the cards fan out from it.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SplashOverlay), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(SplashOverlay), findsNothing);
    expect(find.text('كل كروتك في مكان واحد'), findsOneWidget);
    final shown = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byType(CustomPaint).at(1),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(shown.opacity, 1);
  });

  testWidgets('skip goes straight to the shelf', (tester) async {
    await phone(tester);
    final dependencies = await firstRun();
    await tester.pumpWidget(CardsApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تخطَّ'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingPage), findsNothing);
    expect(dependencies.settings.onboarded, isTrue);
  });

  testWidgets('not for a signed-in customer, nor for a link', (tester) async {
    await phone(tester);
    var dependencies = await firstRun(signedIn: true);
    await tester.pumpWidget(CardsApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingPage), findsNothing);

    dependencies = await firstRun(
      links: LinkInbox(initial: const BrandLink('pubg')),
    );
    await tester.pumpWidget(
      CardsApp(key: UniqueKey(), dependencies: dependencies),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingPage), findsNothing);
    // Still owed: it shows on a plain start later.
    expect(dependencies.settings.onboarded, isFalse);
  });

  testWidgets('on a wide, short screen the picture sits beside the words', (
    tester,
  ) async {
    // The iPhone Duo open.
    await phone(tester, size: const Size(890, 626));
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: OnboardingPage(onDone: () {}),
      ),
    );
    await tester.pumpAndSettle();
    final art = tester.getRect(find.byType(CustomPaint).at(1));
    final title = tester.getRect(find.text('كل كروتك في مكان واحد'));
    expect(art.top, lessThan(title.bottom));
    expect(art.bottom, greaterThan(title.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('it fits the iPhone Duo closed and a small phone', (
    tester,
  ) async {
    for (final size in [const Size(466, 678), const Size(320, 568)]) {
      await phone(tester, size: size);
      await tester.pumpWidget(
        CardsApp(
          key: UniqueKey(),
          dependencies: fixtureDependencies(),
          home: OnboardingPage(onDone: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(find.text('التالي'), findsOneWidget);
    }
  });
}
