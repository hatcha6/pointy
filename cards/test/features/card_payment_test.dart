import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/data/vault/card_vault.dart';
import 'package:pointy_cards/src/features/card_payment/card_number.dart';
import 'package:pointy_cards/src/features/card_payment/card_payment_page.dart';
import 'package:pointy_cards/src/features/card_payment/moamalat_client.dart';
import 'package:pointy_cards/src/features/card_payment/three_ds_view.dart';
import 'package:pointy_cards/src/features/orders/order_progress_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Moamalat's sandbox test card (docs.moamalat.net/testData.html).
const _testCard = '6395 0438 3518 0860';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('card number', () {
    test('passes only numbers with a valid check digit', () {
      expect(CardNumber.isValid(_testCard), isTrue);
      expect(CardNumber.isValid('4111 1111 1111 1111'), isTrue);
      expect(CardNumber.isValid('4111 1111 1111 1112'), isFalse);
      expect(CardNumber.isValid('4111'), isFalse);
      // Arabic-Indic digits from an Arabic keyboard read the same.
      expect(CardNumber.isValid('٤١١١ ١١١١ ١١١١ ١١١١'), isTrue);
    });

    test('names the network from the first digits', () {
      expect(CardNumber.networkOf('4111'), CardNetwork.visa);
      expect(CardNumber.networkOf('5500'), CardNetwork.mastercard);
      expect(CardNumber.networkOf('2221'), CardNetwork.mastercard);
      expect(CardNumber.networkOf('6395'), CardNetwork.local);
      expect(CardNumber.networkOf(''), CardNetwork.unknown);
    });

    test('takes an expiry to come, as month and two-digit year', () {
      final now = DateTime(2026, 10, 25);
      expect(CardNumber.expiry('01/27', now: now), (1, 27));
      expect(CardNumber.expiry('10/26', now: now), (10, 26));
      expect(CardNumber.expiry('09/26', now: now), isNull);
      expect(CardNumber.expiry('13/27', now: now), isNull);
      expect(CardNumber.expiry('01/60', now: now), isNull);
    });

    test('the number groups in fours and the expiry gets its slash', () {
      const number = CardNumberFormatter();
      expect(
        number
            .formatEditUpdate(
              TextEditingValue.empty,
              const TextEditingValue(text: '6395043835180860'),
            )
            .text,
        _testCard,
      );
      const expiry = ExpiryFormatter();
      expect(
        expiry
            .formatEditUpdate(
              TextEditingValue.empty,
              const TextEditingValue(text: '0127'),
            )
            .text,
        '01/27',
      );
    });
  });

  group('Moamalat client', () {
    final session = CardSession.fromJson(fixtureCardSession);
    const card = CardDetails(
      number: '6395043835180860',
      expiryMonth: 1,
      expiryYear: 27,
      name: 'HATEM',
    );

    test('opens the checkout Dafa signed, on the test gateway', () async {
      late http.Request sent;
      final client = MoamalatClient(
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'message': 7,
              'token': 'jwt',
              'orderDetailsModel': {'merchantName': 'TEST', 'currency': 434},
            }),
            200,
          );
        }),
      );
      final checkout = await client.open(session);
      expect(
        sent.url.toString(),
        'https://tnpg.moamalat.net:6008/api/LightboxHostedCheckout',
      );
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['MID'], '10081014649');
      expect(body['Amount'], 10.21);
      expect(body['SecureHashAnonymous'], fixtureCardSession['secure_hash']);
      expect(body['MerchantReference'], 'pay-1-1791849555');
      expect(checkout.token, 'jwt');
    });

    test('a charge the bank stops comes back with its page, then with the '
        "bank's answer finishes as a receipt", () async {
      final bodies = <Map<String, dynamic>>[];
      final headers = <Map<String, String>>[];
      final client = MoamalatClient(
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          headers.add(request.headers);
          final verified =
              (bodies.last['CardPaymentModel'] as Map)['vPCData'] != null;
          return http.Response(
            jsonEncode(
              verified
                  ? {
                      'message': 7,
                      'receiptModel': {
                        'txnDate': '261025213012',
                        'systemReference': '1334761',
                        'networkReference': '628601183699',
                        'merchantReference': 'pay-1-1791849555',
                        'amount': '10210',
                        'currency': '434',
                        'paidThrough': 'Card',
                        'payerAccount': '639504XXXXXX0860',
                        'secureHash': 'A' * 64,
                      },
                    }
                  : {
                      'message': 7,
                      'threeDSSecureModel': {
                        'threeDSURL': 'https://acs.bank.ly/challenge',
                      },
                    },
            ),
            200,
          );
        }),
      );
      final checkout = MoamalatCheckout(
        session: session,
        token: 'jwt',
        merchantName: 'TEST',
        currency: 434,
      );
      final back = Uri.parse('https://relay.preview/v1/customers/card-return');
      final first = await client.charge(checkout, card, returnUrl: back);
      expect(first, isA<ChargeNeedsVerification>());
      expect((first as ChargeNeedsVerification).url.host, 'acs.bank.ly');
      expect(headers.first['Authorization'], 'Bearer jwt');
      final model = bodies.first['CardPaymentModel'] as Map<String, dynamic>;
      expect(model['cardNumber'], '6395043835180860');
      expect(model['expiration'], '0127');
      expect(model['nameOnCard'], 'HATEM');
      expect(model['cVV'], '');
      expect(model['ReturnURL'], back.toString());

      final second = await client.charge(
        checkout,
        card,
        returnUrl: back,
        verification: {'Status': 'Y', 'xid': 'abc'},
      );
      final sentAgain = bodies.last['CardPaymentModel'] as Map<String, dynamic>;
      expect(jsonDecode(sentAgain['vPCData'] as String), {
        'Status': 'Y',
        'xid': 'abc',
      });
      final receipt = (second as ChargeDone).receipt;
      // Under the names Dafa's confirm reads.
      expect(receipt['SystemReference'], '1334761');
      expect(receipt['MerchantReference'], 'pay-1-1791849555');
      expect(receipt['PaidThrough'], 'Card');
      expect(receipt['SecureHash'], 'A' * 64);
    });

    test('a live checkout goes to the live gateway on its own port', () async {
      late Uri sent;
      final client = MoamalatClient(
        client: MockClient((request) async {
          sent = request.url;
          return http.Response(
            jsonEncode({
              'message': 7,
              'token': 'jwt',
              'orderDetailsModel': {'merchantName': 'SHOP', 'currency': 434},
            }),
            200,
          );
        }),
      );
      await client.open(
        CardSession.fromJson({...fixtureCardSession, 'test': false}),
      );
      expect(
        sent.toString(),
        'https://npg.moamalat.net:6016/api/LightboxHostedCheckout',
      );
    });

    test('a refusal carries its code', () async {
      final client = MoamalatClient(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'message': 14}), 200),
        ),
      );
      final checkout = MoamalatCheckout(
        session: session,
        token: 'jwt',
        merchantName: 'TEST',
        currency: 434,
      );
      await expectLater(
        client.charge(checkout, card, returnUrl: Uri.parse('https://x.ly/r')),
        throwsA(
          isA<MoamalatException>().having((e) => e.message, 'message', 14),
        ),
      );
    });
  });

  group('card page', () {
    final order = CardOrder.fromJson(
      fixtureOrder(
        id: 'order-new',
        status: 'awaiting_payment',
        nextAction: 'hosted_page',
      ),
    );

    /// The page on the fake relay; [result] is how it ended.
    Future<List<CardPaymentResult>> openPage(
      WidgetTester tester,
      FakeMoamalatClient moamalat, {
      http.Client? relay,
      CardVault? cards,
    }) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final results = <CardPaymentResult>[];
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(
            moamalat: moamalat,
            client: relay,
            cards: cards,
          ),
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async =>
                    results.add(await CardPaymentPage.open(context, order)),
                child: const Text('pay'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pay'));
      await tester.pumpAndSettle();
      return results;
    }

    Future<void> typeCard(
      WidgetTester tester, {
      String number = _testCard,
    }) async {
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), number);
      await tester.enterText(fields.at(1), '0130');
      await tester.enterText(fields.at(2), 'HATEM ALI');
      await tester.tap(find.textContaining('ادفع'));
      await tester.pumpAndSettle();
    }

    testWidgets('pays the card and hands the order page back the result', (
      tester,
    ) async {
      final moamalat = FakeMoamalatClient();
      final results = await openPage(tester, moamalat);
      expect(find.text('الدفع بالبطاقة المصرفية'), findsOneWidget);
      expect(find.textContaining('10.21'), findsWidgets);
      await typeCard(tester);
      expect(moamalat.charged.single.number, '6395043835180860');
      expect(moamalat.charged.single.expiry, '0130');
      expect(moamalat.charged.single.name, 'HATEM ALI');
      expect(results, [CardPaymentResult.settled]);
    });

    testWidgets("the bank's code step shows inside the page, and its answer "
        'finishes the charge', (tester) async {
      final moamalat = FakeMoamalatClient(verify: true);
      final results = await openPage(tester, moamalat);
      await typeCard(tester);
      expect(find.text('تأكيد من بنكك'), findsOneWidget);
      expect(find.byType(ThreeDSView), findsOneWidget);
      expect(results, isEmpty);

      tester.widget<ThreeDSView>(find.byType(ThreeDSView)).onAnswer({
        'Status': 'Y',
      });
      await tester.pumpAndSettle();
      expect(moamalat.verifications, [
        null,
        {'Status': 'Y'},
      ]);
      expect(results, [CardPaymentResult.settled]);
    });

    testWidgets('closing the bank step goes back to the card, not out', (
      tester,
    ) async {
      final results = await openPage(tester, FakeMoamalatClient(verify: true));
      await typeCard(tester);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('الدفع بالبطاقة المصرفية'), findsOneWidget);
      expect(find.textContaining('لم يكتمل التأكيد من بنكك'), findsOneWidget);
      expect(results, isEmpty);
    });

    testWidgets('a declined card stays on the form with the reason', (
      tester,
    ) async {
      final results = await openPage(tester, FakeMoamalatClient(decline: true));
      await typeCard(tester);
      expect(find.textContaining('رفض البنك العملية'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
      expect(results, isEmpty);
    });

    testWidgets("the name's done key closes the keyboard and pays nothing", (
      tester,
    ) async {
      final moamalat = FakeMoamalatClient();
      final results = await openPage(tester, moamalat);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), _testCard);
      await tester.enterText(fields.at(1), '0130');
      await tester.enterText(fields.at(2), 'HATEM ALI');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(moamalat.charged, isEmpty);
      expect(results, isEmpty);
      expect(tester.testTextInput.isVisible, isFalse);
      // The save switch is still there to turn on before paying.
      expect(find.text('احفظ البطاقة على هذا الهاتف'), findsOneWidget);
    });

    testWidgets('a mistyped number is caught before anything is sent', (
      tester,
    ) async {
      final moamalat = FakeMoamalatClient();
      await openPage(tester, moamalat);
      await typeCard(tester, number: '6395 0438 3518 0861');
      expect(find.text('رقم البطاقة غير صحيح.'), findsOneWidget);
      expect(moamalat.charged, isEmpty);
    });

    testWidgets("without Dafa's session the page hands over to the payment "
        'page', (tester) async {
      final results = await openPage(
        tester,
        FakeMoamalatClient(),
        relay: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 'card_form_unavailable', 'error': 'x'}),
            502,
          ),
        ),
      );
      expect(results, [CardPaymentResult.usePaymentPage]);
    });

    testWidgets('a card is kept on the phone only when asked, and only once '
        'it has paid', (tester) async {
      final cards = MemoryCardVault();
      final declined = FakeMoamalatClient(decline: true);
      await openPage(tester, declined, cards: cards);
      await tester.tap(find.text('احفظ البطاقة على هذا الهاتف'));
      await typeCard(tester);
      expect(
        await cards.cards(),
        isEmpty,
        reason: 'a declined card is not kept',
      );

      declined.decline = false;
      await tester.tap(find.textContaining('ادفع'));
      await tester.pumpAndSettle();
      final kept = await cards.cards();
      expect(kept.single.last4, '0860');
      expect(kept.single.name, 'HATEM ALI');
      expect(kept.single.expiry, '01/30');
    });

    testWidgets('a saved card pays after the phone confirms its owner', (
      tester,
    ) async {
      final cards = MemoryCardVault();
      await cards.keep(
        number: '6395043835180860',
        name: 'HATEM ALI',
        expiryMonth: 1,
        expiryYear: 30,
      );
      final moamalat = FakeMoamalatClient();
      final results = await openPage(tester, moamalat, cards: cards);
      expect(find.text('بطاقاتك المحفوظة'), findsOneWidget);
      expect(find.text('•••• 0860'), findsOneWidget);
      // No fields: the saved card is the one chosen.
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.textContaining('ادفع'));
      await tester.pumpAndSettle();
      expect(cards.reads, 1);
      expect(moamalat.charged.single.number, '6395043835180860');
      expect(moamalat.charged.single.name, 'HATEM ALI');
      expect(results, [CardPaymentResult.settled]);
    });

    testWidgets('a saved card is not used when the phone cannot confirm its '
        'owner', (tester) async {
      final cards = MemoryCardVault(allowRead: false);
      await cards.keep(
        number: '6395043835180860',
        name: 'HATEM ALI',
        expiryMonth: 1,
        expiryYear: 30,
      );
      final moamalat = FakeMoamalatClient();
      final results = await openPage(tester, moamalat, cards: cards);
      await tester.tap(find.textContaining('ادفع'));
      await tester.pumpAndSettle();
      expect(find.textContaining('لم يتم التحقق من هويتك'), findsOneWidget);
      expect(moamalat.charged, isEmpty);
      expect(results, isEmpty);
      // Another card is still one tap away.
      await tester.tap(find.text('استخدم بطاقة أخرى'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(3));
    });
  });

  group('backing out', () {
    final order = CardOrder.fromJson({
      ...fixtureOrder(
        id: 'order-new',
        status: 'awaiting_payment',
        nextAction: 'hosted_page',
      ),
      'checkout_url': 'https://localbankcards.dafa.ly/pay-1',
    });

    Future<void> openOrder(WidgetTester tester, {http.Client? relay}) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        CardsApp(
          dependencies: fixtureDependencies(client: relay),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      OrderProgressPage.open(context, order: order),
                  child: const Text('order'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('order'));
      await tester.pumpAndSettle();
      // The card form opens over the order on its own.
      expect(find.text('الدفع بالبطاقة المصرفية'), findsOneWidget);
    }

    testWidgets('closing the card form calls the order off and goes back, '
        'with no wait for a payment', (tester) async {
      await openOrder(tester);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump();
      // Never the "finish paying on the card page" wait.
      expect(find.text('أكمل الدفع في صفحة البطاقة'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('تم إلغاء الطلب.'), findsOneWidget);
      expect(find.text('order'), findsOneWidget);
      expect(find.byType(OrderProgressPage), findsNothing);
    });

    testWidgets('when the cancel cannot reach the relay, the order offers '
        'to pay or cancel instead of spinning', (tester) async {
      final relay = fixtureRelay();
      await openOrder(
        tester,
        relay: MockClient((request) async {
          if (request.url.path.endsWith('/cancel')) {
            throw http.ClientException('offline');
          }
          final copy = http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..body = request.body;
          return relay.send(copy).then(http.Response.fromStream);
        }),
      );
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('لم يكتمل الدفع'), findsOneWidget);
      expect(find.text('أكمل الدفع'), findsOneWidget);
      expect(find.text('إلغاء الطلب'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Leaving the order stops its watch.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
