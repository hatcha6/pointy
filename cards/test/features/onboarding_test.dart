import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/push/push.dart';
import 'package:pointy_cards/src/data/settings/app_settings.dart';
import 'package:pointy_cards/src/dependencies.dart';
import 'package:pointy_cards/src/features/attribution/heard_from_form.dart';
import 'package:pointy_cards/src/features/links/cards_link.dart';
import 'package:pointy_cards/src/features/links/link_inbox.dart';
import 'package:pointy_cards/src/features/onboarding/onboarding_art.dart';
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
  Push? push,
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
    push: push,
  );
}

/// Walks the first three steps to the notifications one. Its bell rings on
/// and on, so from here time is pumped, never settled.
Future<void> toNotifications(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.tap(find.text('التالي'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
}

/// On «من أين سمعت عنا؟», the onboarding's last step: skipped, so the app
/// opens. Pumped, not settled: the bell may still be ringing behind it.
Future<void> skipQuestion(WidgetTester tester) async {
  expect(find.byType(HeardFromForm), findsOneWidget);
  await tester.tap(find.text('تخطَّ'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets(
    'a first run walks three steps, asks where they heard of us, then the shelf, once',
    (tester) async {
      await phone(tester);
      final dependencies = await firstRun();
      await tester.pumpWidget(CardsApp(dependencies: dependencies));
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.text('كل كروتك في مكان واحد'), findsOneWidget);
      // Three steps and the question.
      expect(find.bySemanticsLabel('الخطوة 1 من 4'), findsOneWidget);

      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
      expect(find.text('ادفع، ويصلك الرقم فوراً'), findsOneWidget);

      // Swiping works as well as the button (right to left: the next step is
      // to the left).
      await tester.drag(find.byType(PageView), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('كروتك محفوظة بأمان'), findsOneWidget);
      expect(find.bySemanticsLabel('الخطوة 3 من 4'), findsOneWidget);

      // A question follows, so the last picture's button goes on rather
      // than starting: «من أين سمعت عنا؟» is the onboarding's own last step.
      expect(find.text('ابدأ الآن'), findsNothing);
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle();
      expect(find.byType(HeardFromForm), findsOneWidget);
      expect(find.bySemanticsLabel('الخطوة 4 من 4'), findsOneWidget);
      expect(find.text('كروتك محفوظة بأمان'), findsNothing);
      // Nothing chosen yet: nothing to send.
      FilledButton next() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'متابعة'),
      );
      expect(next().onPressed, isNull);
      await tester.tap(find.text('صديق أو قريب'));
      await tester.pump();
      expect(next().onPressed, isNotNull);
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingPage), findsNothing);
      expect(dependencies.settings.onboarded, isTrue);
      expect(find.text('ليبيانا'), findsWidgets);
      expect(dependencies.attribution.asked, isTrue);
      // Signed out: the answer waits for the sign-in.
      expect(dependencies.attribution.pending.heardFrom, 'friend');

      // Kept: the next start goes straight to the shelf.
      final again = AppSettings(preferences: SharedPreferencesAsync());
      await again.load();
      expect(again.onboarded, isTrue);
    },
  );

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

  testWidgets('skip goes to the question, and skipping it to the shelf', (
    tester,
  ) async {
    await phone(tester);
    final dependencies = await firstRun();
    await tester.pumpWidget(CardsApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تخطَّ'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('الخطوة 4 من 4'), findsOneWidget);
    await skipQuestion(tester);
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingPage), findsNothing);
    // Skipped: not asked again.
    expect(dependencies.attribution.asked, isTrue);
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

  testWidgets('side by side, the question keeps the picture in its column', (
    tester,
  ) async {
    final picture = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is OnboardingArtPainter,
    );
    for (final size in const [Size(926, 428), Size(1180, 820)]) {
      // A phone on its side, an iPad in landscape.
      await phone(tester, size: size);
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(),
          home: OnboardingPage(
            // A new page for each screen, not the last one's state.
            key: ValueKey(size),
            askHeardFrom: true,
            onDone: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the steps at $size');
      final before = tester.getRect(picture);
      await tester.tap(find.text('تخطَّ'));
      await tester.pump();
      // Midway: smaller already, and still in its column.
      await tester.pump(const Duration(milliseconds: 400));
      final midway = tester.getRect(picture);
      expect(midway.center.dx, moreOrLessEquals(before.center.dx, epsilon: 1));
      expect(midway.width, lessThan(before.width));
      await tester.pumpAndSettle();
      final after = tester.getRect(picture);
      final title = tester.getRect(find.text('من أين سمعت عن دفتر كروت؟'));
      // Same column, a little smaller, beside the question (right to left:
      // the picture on the right).
      expect(after.center.dx, moreOrLessEquals(before.center.dx, epsilon: 1));
      expect(after.width, moreOrLessEquals(before.width * 0.8, epsilon: 1));
      expect(after.left, greaterThan(title.right));
      // Shown, not just built: the first answer can be tapped.
      expect(find.text('فيسبوك').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('turning the screen mid-onboarding keeps the step, no crash', (
    tester,
  ) async {
    // PostHog: "Bad state: Too many elements" on the web, when the layout
    // flipped and two page views held the controller for a frame.
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: OnboardingPage(onDone: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    for (final size in const [Size(890, 626), Size(390, 844), Size(890, 626)]) {
      tester.view.physicalSize = size * 3;
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    // Still on the second step: the swipe moved with the layout.
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(pages.page, 1);
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
      // The notifications step's second button fits too.
      await toNotifications(tester);
      expect(tester.takeException(), isNull, reason: '$size notifications');
      expect(find.text('ليس الآن'), findsOneWidget);
    }
  });

  testWidgets('a phone offers notifications last, and turns them on', (
    tester,
  ) async {
    await phone(tester);
    final push = FixturePush();
    final dependencies = await firstRun(push: push);
    await tester.pumpWidget(CardsApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('الخطوة 1 من 5'), findsOneWidget);

    await toNotifications(tester);
    expect(find.text('العروض تصلك أولاً'), findsOneWidget);
    expect(find.text('ابدأ الآن'), findsNothing);
    await tester.tap(find.text('تفعيل الإشعارات'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(push.enabled, isTrue);
    await skipQuestion(tester);
    expect(find.byType(OnboardingPage), findsNothing);
    expect(dependencies.settings.onboarded, isTrue);
  });

  testWidgets('«ليس الآن» starts the app without asking', (tester) async {
    await phone(tester);
    final push = FixturePush();
    final dependencies = await firstRun(push: push);
    await tester.pumpWidget(CardsApp(dependencies: dependencies));
    await tester.pumpAndSettle();

    await toNotifications(tester);
    await tester.tap(find.text('ليس الآن'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(push.enabled, isFalse);
    await skipQuestion(tester);
    expect(find.byType(OnboardingPage), findsNothing);
  });

  testWidgets('notifications already on: the step says so and finishes', (
    tester,
  ) async {
    await phone(tester);
    final push = FixturePush();
    await push.setEnabled(true);
    final dependencies = await firstRun(push: push);
    await tester.pumpWidget(CardsApp(dependencies: dependencies));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('الخطوة 1 من 5'), findsOneWidget);

    await toNotifications(tester);
    expect(find.text('العروض تصلك أولاً'), findsOneWidget);
    expect(find.textContaining('الإشعارات مفعّلة'), findsOneWidget);
    expect(find.text('تفعيل الإشعارات'), findsNothing);
    expect(find.text('ليس الآن'), findsNothing);
    await tester.tap(find.text('التالي'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(push.enabled, isTrue);
    await skipQuestion(tester);
    expect(find.byType(OnboardingPage), findsNothing);
    expect(dependencies.settings.onboarded, isTrue);
  });
}
