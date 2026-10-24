import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';
import 'package:pointy_cards/src/features/sign_in/sign_in_sheet.dart';

CardBrand brandAt(int index) => CardBrand.fromJson(
  (fixtureCatalog['brands'] as List)[index] as Map<String, dynamic>,
);

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

  testWidgets(
    'a tile turns into the brand header as it flies, shade included',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ليبيانا').first);
      await tester.pump();
      // Mid-flight: the flying art already carries part of the header's shade,
      // so it never lands bare over the page and then snaps.
      await tester.pump(const Duration(milliseconds: 150));
      final shades = tester
          .widgetList<Opacity>(find.byType(Opacity))
          // The header's shade: a gradient (a muted tile is a plain fade).
          .where(
            (o) =>
                o.child is DecoratedBox &&
                ((o.child! as DecoratedBox).decoration as BoxDecoration)
                        .gradient !=
                    null,
          )
          .map((o) => o.opacity)
          .where((v) => v > 0 && v < 1);
      expect(shades, isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('اختر الفئة'), findsOneWidget);
    },
  );

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

  testWidgets('my cards and the account', (tester) async {
    await phone(tester);
    await tester.pumpWidget(CardsApp(dependencies: fixtureDependencies()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('كروتي').last);
    await tester.pumpAndSettle();
    // The section title and the order's pill.
    expect(find.text('قيد التجهيز'), findsWidgets);
    expect(find.text('أُعيد لرصيدك'), findsOneWidget);
    // Open orders first.
    expect(
      tester.getTopLeft(find.text('ببجي موبايل · 60 شدة')).dy,
      lessThan(tester.getTopLeft(find.text('ليبيانا · 10 دينار')).dy),
    );

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
