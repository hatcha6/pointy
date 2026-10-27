import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/vault/code_vault.dart';
import 'package:pointy_cards/src/dependencies.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/home/shelf_reveal.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';
import 'package:pointy_cards/src/features/sign_in/sign_in_sheet.dart';
import 'package:pointy_cards/src/shared/card_art.dart';

CardBrand brandAt(int index) => CardBrand.fromJson(
  (fixtureCatalog['brands'] as List)[index] as Map<String, dynamic>,
);

/// Face ID that is locked until asked, then says yes.
class _FaceId extends CodeLock {
  bool _open = false;

  @override
  bool get isUnlocked => _open;

  @override
  Future<bool> unlock(String reason) async => _open = true;
}

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the shelf: right to left, categories, forgiving search', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Directionality>(find.byType(Directionality).first)
          .textDirection,
      TextDirection.rtl,
    );
    expect(find.text('ليبيانا'), findsWidgets);
    expect(find.text('اشترِ مجدداً'), findsOneWidget);
    expect(find.text('رصيدك 10.00 د.ل'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'ببجى');
    await tester.pumpAndSettle();
    expect(find.text('ببجي موبايل'), findsWidgets);
    expect(find.text('المدار'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'xyz');
    await tester.pumpAndSettle();
    expect(find.text('لا نتائج لـ «xyz»'), findsOneWidget);
  });

  testWidgets('the brand page shows the whole card, never past its art', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ليبيانا').first);
    await tester.pump();
    // Mid-flight: one card moving, already the card's own shape.
    await tester.pump(const Duration(milliseconds: 150));
    final flying = tester.getSize(find.byType(CardArt).last);
    expect(flying.width / flying.height, closeTo(kCardAspect, 0.01));
    await tester.pumpAndSettle();
    expect(find.text('اختر الفئة'), findsOneWidget);

    // Landed: uncropped 16:10, at most the 800 px art's width at 3x, and the
    // header leaves most of the phone to the values.
    final header = find.descendant(
      of: find.byType(BrandPage),
      matching: find.byType(CardArt),
    );
    final card = tester.getSize(header.first);
    expect(card.width, lessThanOrEqualTo(800 / 3));
    expect(card.width / card.height, closeTo(kCardAspect, 0.01));
    expect(tester.getBottomLeft(header.first).dy, lessThan(844 * 0.36));
    // No rules around the name: the page is the card, then its values.
    expect(
      find.descendant(
        of: find.byType(BrandPage),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
    // The card flies back on the iPhone's edge swipe too.
    expect(
      tester
          .widgetList<Hero>(find.byType(Hero))
          .where((h) => '${h.tag}'.startsWith('brand-'))
          .every((h) => h.transitionOnUserGestures),
      isTrue,
    );
  });

  testWidgets('the iPhone\'s edge swipe flies the card back to its tile', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    // The card's glow: the blurred art under it, on the brand page.
    double glow() => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.descendant(
                  of: find.byType(BrandPage),
                  matching: find.byType(ImageFiltered),
                ),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;

    await tester.tap(find.text('ليبيانا').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // In flight: the card is not home yet, so neither is its light.
    expect(glow(), 0);
    await tester.pumpAndSettle();
    expect(glow(), greaterThan(0));
    // The page's card and the tile it came from share a tag. In flight,
    // both Heroes stand in as empty placeholders while the card flies above.
    final tag = tester.widget<BrandPage>(find.byType(BrandPage)).heroTag;
    int drawn() => find
        .descendant(
          of: find.byWidgetPredicate((w) => w is Hero && w.tag == tag),
          matching: find.byType(CardArt),
        )
        .evaluate()
        .length;
    expect(drawn(), 1);

    // Right to left: the back swipe starts at the right edge.
    final gesture = await tester.startGesture(const Offset(388, 400));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(drawn(), 0);
    // The swipe put the glow out before the card left it behind.
    await tester.pump(const Duration(milliseconds: 150));
    expect(glow(), 0);

    await gesture.moveBy(const Offset(-160, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(BrandPage), findsNothing);

    // Leaving by the back button: the light goes out first, then the card
    // flies home.
    await tester.tap(find.text('ليبيانا').first);
    await tester.pumpAndSettle();
    expect(glow(), greaterThan(0));
    await tester.tap(find.byType(BackButtonIcon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(glow(), 0);
    expect(drawn(), 0);
    await tester.pumpAndSettle();
    expect(find.byType(BrandPage), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('choosing a value never reflows its tile', (tester) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ليبيانا').first);
    await tester.pumpAndSettle();
    final tile = find
        .ancestor(
          of: find.text('10 دينار'),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    final label = find.text('10 دينار');
    final before = (tester.getSize(tile), tester.getSize(label));
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect((tester.getSize(tile), tester.getSize(label)), before);
  });

  testWidgets('«عرض الكل» dips the shelves out and raises the category in', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    final seeAll = find.text('عرض الكل');
    await tester.ensureVisible(seeAll.first);
    await tester.pumpAndSettle();
    Iterable<double> opacities() => tester
        .widgetList<Opacity>(
          find.descendant(
            of: find.byType(ShelfRise),
            matching: find.byType(Opacity),
          ),
        )
        .map((o) => o.opacity);

    await tester.tap(seeAll.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // Mid-way out: the shelves are fading, not snapped away.
    expect(seeAll, findsWidgets);
    expect(opacities().any((o) => o > 0 && o < 1), isTrue);

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 100));
    // The category's grid is rising in, the first tiles ahead of the rest.
    expect(seeAll, findsNothing);
    expect(opacities().any((o) => o < 1), isTrue);

    await tester.pumpAndSettle();
    expect(opacities().every((o) => o == 1), isTrue);
  });

  testWidgets('the home tab starts the shelf over: search, category, top', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    final seeAll = find.text('عرض الكل');
    final field = find.byType(TextField).first;
    ScrollPosition page() =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;

    await tester.enterText(field, 'ببجى');
    await tester.pumpAndSettle();
    expect(seeAll, findsNothing);
    await tester.tap(find.text('الرئيسية'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(seeAll, findsWidgets);

    // Down the page, into a category.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(page().pixels, greaterThan(0));
    await tester.tap(seeAll.first);
    await tester.pumpAndSettle();
    expect(seeAll, findsNothing);

    await tester.tap(find.text('الرئيسية'));
    await tester.pumpAndSettle();
    expect(seeAll, findsWidgets);
    expect(page().pixels, 0);

    // From another tab, the shelf is simply back at its start.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حسابي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الرئيسية'));
    await tester.pumpAndSettle();
    expect(page().pixels, 0);
  });

  testWidgets('«عرض الكل» brings its category into the bar\'s view', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    // The last shelf's «عرض الكل»: its category sits off the bar's far end.
    final seeAll = find.text('عرض الكل');
    await tester.scrollUntilVisible(
      seeAll.last,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    // Before: the bar's last category is past its left edge (right to left).
    final items = find.byWidgetPredicate(
      (w) => w is Semantics && w.key is GlobalKey,
    );
    expect(tester.getRect(items.last).left, lessThan(0));
    // Clear the tab bar the shelf scrolls under.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(seeAll.last);
    await tester.pumpAndSettle();

    // The bar's own selected item (the tab bar's is not a category).
    final chip = find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.key is GlobalKey &&
          (w.properties.selected ?? false),
    );
    final rect = tester.getRect(chip);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
  });

  testWidgets(
    'a brand: values, an unavailable one, the total follows the quantity',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(),
          home: BrandPage(brand: brandAt(0)),
        ),
      );
      await tester.pumpAndSettle();

      // The buy bar's total sits beside the value tile's own price.
      expect(find.text('5.00 د.ل'), findsNWidgets(2));
      expect(find.text('كرت واحد'), findsOneWidget);
      expect(find.text('غير متوفر الآن'), findsOneWidget);
      await tester.tap(find.text('10 دينار'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('زيادة الكمية'));
      await tester.pumpAndSettle();
      expect(find.text('كرتان'), findsOneWidget);
      // The 20 دينار tile and the bar's total for two tens.
      expect(find.text('20.00 د.ل'), findsNWidgets(2));
    },
  );

  testWidgets(
    'buying: payer details after pay, the wallet code, then the card',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(),
          home: BrandPage(brand: brandAt(0)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 دينار'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اشترِ'));
      await tester.pumpAndSettle();

      // Credit 10 covers it: pay from credit, no fee.
      expect(find.text('ادفع من رصيدك'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('رسوم الدفع'), findsOneWidget);
      // The method row opens the picker.
      await tester.tap(find.text('تغيير'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سداد'));
      await tester.pumpAndSettle();
      expect(find.text('ادفع 10.21 د.ل'), findsWidgets);

      await tester.tap(find.widgetWithText(FilledButton, 'ادفع 10.21 د.ل'));
      await tester.pumpAndSettle();
      // The payer dialog: the signed-in number is offered, the birth year asked.
      expect(find.text('091 234 5678'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'سنة الميلاد'),
        '1990',
      );
      await tester.tap(find.text('متابعة'));
      await tester.pumpAndSettle();

      expect(find.text('رمز تأكيد سداد'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '111111');
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد الدفع'));
      await tester.pumpAndSettle();

      expect(find.byType(RevealPage), findsOneWidget);
      // On the flipped card and in the code card.
      expect(find.text('4827 1930 5561 2208'), findsWidgets);
    },
  );

  testWidgets('the reveal: copy, and dialing only where the hint spells it', (
    tester,
  ) async {
    await phone(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: RevealPage(
          order: CardOrder.fromJson(fixtureOrder()),
          brand: brandAt(1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The card has turned over: the code is on its face.
    expect(find.text('4827 1930 5561 2208'), findsOneWidget);
    expect(find.text('اشحن الآن'), findsOneWidget);
    await tester.tap(find.byTooltip('نسخ'));
    await tester.pumpAndSettle();
    expect(copied, ['4827 1930 5561 2208']);
    expect(find.text('تم نسخ الرقم السري'), findsOneWidget);

    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: RevealPage(
          order: CardOrder.fromJson(fixtureOrder()),
          brand: brandAt(0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('اشحن الآن'), findsNothing);
  });

  testWidgets(
    'sign-in: a wrong number is told, a right one moves to the code',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(signedIn: false),
          home: const Scaffold(body: SignInSheet()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0212345678');
      await tester.tap(find.text('أرسل الرمز'));
      await tester.pumpAndSettle();
      expect(
        find.text('أدخل رقم هاتف ليبياً صحيحاً يبدأ بـ 09'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), '091 234 5678');
      await tester.tap(find.text('أرسل الرمز'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل الرمز'), findsOneWidget);
      expect(find.textContaining('091 234 5678'), findsOneWidget);
      // Discard the resend countdown's timer.
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('after Face ID the saved card turns over to its code', (
    tester,
  ) async {
    await phone(tester);
    final fixtures = fixtureDependencies();
    await tester.pumpWidget(
      CardsApp(
        dependencies: CardsDependencies(
          config: fixtures.config,
          auth: fixtures.auth,
          catalog: fixtures.catalog,
          orders: fixtures.orders,
          vault: fixtures.vault,
          lock: _FaceId(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('كروتي').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ليبيانا · 10 دينار'));
    await tester.pumpAndSettle();
    expect(find.text('رموزك محمية'), findsOneWidget);
    final code = find.text('4827 1930 5561 2208');
    expect(code, findsNothing);

    await tester.tap(find.text('اعرض الرموز'));
    await tester.pump();
    // Face ID's sheet is still clearing: nothing has moved yet.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('رموزك محمية'), findsOneWidget);
    expect(code, findsNothing);

    // The sheet has cleared: the panel below is rising, the card turning.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 120));
    final rising = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.textContaining('LY-00981234'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(rising.opacity.value, inExclusiveRange(0, 1));
    // Past half a turn, the back with the code faces the customer.
    await tester.pump(const Duration(milliseconds: 400));
    expect(code, findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('رموزك محمية'), findsNothing);
    expect(code, findsOneWidget);
  });

  testWidgets('my cards and the account', (tester) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('كروتي').last);
    await tester.pumpAndSettle();
    // The section title and the order's pill.
    expect(find.text('قيد التجهيز'), findsWidgets);
    // A purchase that did not go through stays out of «الكل»…
    expect(find.text('أُعيد لرصيدك'), findsNothing);
    // Open orders first.
    expect(
      tester.getTopLeft(find.text('ببجي موبايل · 60 شدة')).dy,
      lessThan(tester.getTopLeft(find.text('ليبيانا · 10 دينار')).dy),
    );
    // …and waits under its own filter, without the delivered cards.
    await tester.tap(find.text('لم تكتمل'));
    await tester.pumpAndSettle();
    expect(find.text('أُعيد لرصيدك'), findsOneWidget);
    expect(find.text('ليبيانا · 10 دينار'), findsNothing);

    await tester.tap(find.text('حسابي'));
    await tester.pumpAndSettle();
    expect(find.text('10.00 د.ل'), findsWidgets);
    expect(find.text('هذا الجهاز'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('حذف الحساب'), 200);
    // Clear the frosted tab bar the page scrolls under.
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف الحساب'));
    await tester.pumpAndSettle();
    expect(find.text('حذف حسابك؟'), findsOneWidget);
  });

  test('a purchase tells the shelf to refresh', () async {
    final dependencies = fixtureDependencies();
    var changed = 0;
    dependencies.orders.changes.addListener(() => changed++);
    await dependencies.orders.confirm('order-new', '111111');
    expect(changed, 1);
  });
}
