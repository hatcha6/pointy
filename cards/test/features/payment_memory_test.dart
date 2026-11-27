import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/vault/payer_vault.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/card_payment/saved_payments_page.dart';
import 'package:pointy_cards/src/features/checkout/checkout_model.dart';
import 'package:pointy_cards/src/features/checkout/payment_memory.dart';

const sadad = PaymentMethod(
  key: 'dafa_sadad',
  provider: 'sadad',
  name: 'سداد',
  kind: 'otp',
  payer: 'phone',
  birthYear: true,
);

CardOrder order(String id, {String method = 'dafa_sadad'}) =>
    CardOrder.fromJson(
      fixtureOrder(id: id, status: 'delivered', method: method),
    );

CardBrand libyana() => CardBrand.fromJson(
  (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
);

void main() {
  group('what is remembered', () {
    test(
      'the way to pay and the number, once a payment goes through',
      () async {
        final memory = PaymentMemory(payers: MemoryPayerVault());
        await memory.load();
        expect(memory.lastMethod, isNull);

        await memory.expect(
          order('a'),
          sadad,
          payer: '0912345678',
          birthYear: '1990',
        );
        // Placed is not paid: nothing yet.
        expect(memory.saved, isEmpty);
        expect(memory.lastMethod, isNull);

        await memory.paid(order('a'));
        expect(memory.lastMethod, 'dafa_sadad');
        final kept = memory.payerFor('dafa_sadad')!;
        expect(kept.payer, '0912345678');
        expect(kept.birthYear, '1990');
        expect(kept.masked, '0912 ••• 678');
      },
    );

    test('an order seen paid before the checkout said its payer', () async {
      final memory = PaymentMemory(payers: MemoryPayerVault());
      await memory.paid(order('b'));
      await memory.expect(
        order('b'),
        sadad,
        payer: '0921111111',
        birthYear: '1985',
      );
      expect(memory.payerFor('dafa_sadad')?.payer, '0921111111');
    });

    test('not kept when asked not to, nor for an order never paid', () async {
      final memory = PaymentMemory(payers: MemoryPayerVault());
      await memory.expect(order('c'), sadad, payer: '0911', remember: false);
      await memory.paid(order('c'));
      expect(memory.saved, isEmpty);
      await memory.expect(order('d'), sadad, payer: '0912345678');
      expect(memory.saved, isEmpty);
    });

    test(
      'credit alone teaches no way to pay; forgetting and clearing',
      () async {
        final memory = PaymentMemory(
          payers: MemoryPayerVault([
            const SavedPayer(
              method: 'dafa_edfali',
              provider: 'edfali',
              methodName: 'إدفعلي',
              payer: '0911111111',
              kind: 'phone',
            ),
          ]),
        );
        await memory.paid(order('e', method: ''));
        expect(memory.lastMethod, isNull);
        expect(memory.saved, hasLength(1));
        await memory.forget('dafa_edfali');
        expect(memory.saved, isEmpty);
        await memory.paid(order('f'));
        await memory.clear();
        expect(memory.lastMethod, isNull);
      },
    );
  });

  group('the checkout', () {
    test(
      'starts on the way that last went through, paying from its number',
      () async {
        final dependencies = fixtureDependencies();
        await dependencies.payments.expect(
          order('x', method: 'dafa_edfali'),
          sadad.copyWithKey('dafa_edfali'),
          payer: '0925555555',
        );
        await dependencies.payments.paid(order('x', method: 'dafa_edfali'));

        final model = CheckoutModel(
          orders: dependencies.orders,
          brand: libyana(),
          item: libyana().items[1],
          payments: dependencies.payments,
        )..setUseCredit(false);
        await model.load();
        model.setUseCredit(false);
        expect(model.method?.key, 'dafa_edfali');
        expect(model.payer?.payer, '0925555555');
        expect(model.mustAskPayer, isFalse);

        // Sadad asks a birth year none was kept with: asked.
        model.choose(
          model.options!.methods.firstWhere((m) => m.key == 'dafa_sadad'),
        );
        expect(model.mustAskPayer, isTrue);
      },
    );
  });

  testWidgets('paid once from a wallet: the next checkout is one tap, and '
      'the settings show it', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final dependencies = fixtureDependencies();
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: BrandPage(brand: libyana()),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> checkout() async {
      await tester.tap(find.text('10 دينار'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اشترِ'));
      await tester.pumpAndSettle();
      // Paid by the wallet, not the credit.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
    }

    Future<void> enterCode() async {
      expect(find.text('رمز تأكيد سداد'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '111111');
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد الدفع'));
      await tester.pumpAndSettle();
    }

    // First time: Sadad picked, the number and birth year asked.
    await checkout();
    await tester.tap(find.text('تغيير'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('سداد'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'ادفع 10.21 د.ل'));
    await tester.pumpAndSettle();
    expect(find.text('احفظ الرقم لدفعاتي القادمة'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'سنة الميلاد'),
      '1990',
    );
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    await enterCode();
    expect(dependencies.payments.lastMethod, 'dafa_sadad');
    expect(dependencies.payments.payerFor('dafa_sadad')?.birthYear, '1990');

    // Back on the brand's page, a second order: Sadad already chosen, the
    // number shown, and «ادفع» goes straight to the wallet's code.
    await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(BrandPage), findsOneWidget);
    await checkout();
    expect(find.text('سداد'), findsOneWidget);
    expect(find.text('يُدفع من'), findsOneWidget);
    expect(find.text('0912 ••• 678'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'ادفع 10.21 د.ل'));
    await tester.pumpAndSettle();
    expect(find.text('احفظ الرقم لدفعاتي القادمة'), findsNothing);
    expect(find.text('رمز تأكيد سداد'), findsOneWidget);
  });

  testWidgets('the settings list the preferred way and the wallets, each '
      'removable', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final dependencies = fixtureDependencies(
      payers: MemoryPayerVault([
        const SavedPayer(
          method: 'dafa_sadad',
          provider: 'sadad',
          methodName: 'سداد',
          payer: '0912345678',
          birthYear: '1990',
          kind: 'phone',
        ),
      ]),
    );
    await dependencies.payments.paid(order('p'));
    await tester.pumpWidget(
      CardsApp(dependencies: dependencies, home: const SavedPaymentsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('طريقتك المفضّلة'), findsOneWidget);
    expect(find.text('0912 ••• 678'), findsOneWidget);
    expect(find.text('· مع سنة الميلاد'), findsOneWidget);
    expect(find.text('البطاقات المصرفية'), findsOneWidget);

    await tester.tap(find.text('إزالة').last);
    await tester.pumpAndSettle();
    expect(find.text('إزالة الرقم المحفوظ؟'), findsOneWidget);
    await tester.tap(find.text('إزالة').last);
    await tester.pumpAndSettle();
    expect(find.text('0912 ••• 678'), findsNothing);
    expect(dependencies.payments.saved, isEmpty);
  });
}

extension on PaymentMethod {
  PaymentMethod copyWithKey(String key) => PaymentMethod(
    key: key,
    provider: 'edfali',
    name: 'إدفعلي',
    kind: kind,
    payer: payer,
    birthYear: false,
  );
}
