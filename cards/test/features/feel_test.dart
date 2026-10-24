import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/dev/preview_scenarios.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/customer.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/orders/order_progress_page.dart';
import 'package:pointy_cards/src/features/orders/order_watcher.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';
import 'package:pointy_cards/src/features/sign_in/sign_in_sheet.dart';
import 'package:pointy_cards/src/shared/shake.dart';

/// The haptics the app asked for, by kind.
List<String> recordHaptics(WidgetTester tester) {
  final felt = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        felt.add('${call.arguments}'.replaceFirst('HapticFeedbackType.', ''));
      }
      return null;
    },
  );
  return felt;
}

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Buys Libyana 10 with Sadad up to the wallet code, as a customer would.
Future<void> buyWithSadad(
  WidgetTester tester,
  PreviewScenarios scenarios,
) async {
  await tester.pumpWidget(
    CardsApp(
      dependencies: fixtureDependencies(scenarios: scenarios),
      home: BrandPage(
        brand: CardBrand.fromJson(
          (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('10 دينار'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('اشترِ'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(Switch));
  await tester.pumpAndSettle();
  await tester.tap(find.text('تغيير'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('سداد'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'ادفع 10.21 د.ل'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextFormField, 'سنة الميلاد'),
    '1990',
  );
  await tester.tap(find.text('متابعة'));
  await tester.pumpAndSettle();
}

Future<void> confirmCode(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).last, '111111');
  await tester.pumpAndSettle();
  await tester.tap(find.text('تأكيد الدفع'));
  await tester.pump();
}

void main() {
  testWidgets('a wrong code is felt, shaken off and cleared', (tester) async {
    await phone(tester);
    final felt = recordHaptics(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(signedIn: false),
        home: Scaffold(
          body: SignInSheet(
            initialChallenge: CodeChallenge(
              phone: '218912345678',
              phoneMasked: '091•••678',
              codeLength: 6,
              expiresAt: null,
              resendAt: DateTime.now(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The fake relay knows no code: every one is refused.
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(felt, contains('errorNotification'));
    // The shake's own swing is the outermost transform under it.
    final swing = tester.widget<Transform>(
      find
          .descendant(of: find.byType(Shake), matching: find.byType(Transform))
          .first,
    );
    expect(swing.transform.getTranslation().x, isNot(0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refund lands calmly: a warning, and where the money went', (
    tester,
  ) async {
    await phone(tester);
    final felt = recordHaptics(tester);
    final dependencies = fixtureDependencies(
      client: fixtureRelay(orderStatus: 'refunded'),
    );
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: OrderProgressPage(
          openPaymentPage: false,
          watcher: OrderWatcher(
            orders: dependencies.orders,
            vault: dependencies.vault,
            order: CardOrder.fromJson(fixtureOrder(status: 'fulfilling')),
          )..start(),
        ),
      ),
    );
    // The relay answers the next poll with the refund.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('لم نتمكن من شراء الكرت'), findsOneWidget);
    expect(find.textContaining('+ 10.00 د.ل'), findsOneWidget);
    expect(find.textContaining('أُضيف إلى رصيدك'), findsOneWidget);
    expect(felt, ['warningNotification']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a paid order that ends in a refund reaches its page and says so',
    (tester) async {
      await phone(tester);
      final felt = recordHaptics(tester);
      final scenarios = PreviewScenarios()..choose(PreviewOutcome.refunded);
      await buyWithSadad(tester, scenarios);
      await confirmCode(tester);
      await tester.pumpAndSettle();
      // Paid: the sheet hands the order on, and it is being prepared.
      expect(find.byType(OrderProgressPage), findsOneWidget);
      expect(felt, contains('successNotification'));
      // Two polls later the card could not be bought.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('لم نتمكن من شراء الكرت'), findsOneWidget);
      expect(find.textContaining('+ 10.00 د.ل'), findsOneWidget);
      expect(felt.last, 'warningNotification');
      // The next purchase moves on by itself.
      expect(scenarios.next, PreviewOutcome.review);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a wrong wallet code shakes once, the right one goes through', (
    tester,
  ) async {
    await phone(tester);
    final felt = recordHaptics(tester);
    final scenarios = PreviewScenarios()..choose(PreviewOutcome.wrongCode);
    await buyWithSadad(tester, scenarios);
    await confirmCode(tester);
    await tester.pumpAndSettle();
    expect(felt, contains('errorNotification'));
    expect(find.text('رمز تأكيد سداد'), findsOneWidget);
    await confirmCode(tester);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(RevealPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
