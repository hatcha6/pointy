import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/accounts/saved_accounts.dart';
import 'package:pointy_cards/src/data/models/account_target.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/checkout/checkout_sheet.dart';
import 'package:pointy_cards/src/features/my_cards/my_cards_page.dart';
import 'package:pointy_cards/src/features/orders/order_progress_page.dart';
import 'package:pointy_cards/src/features/orders/order_watcher.dart';
import 'package:pointy_cards/src/features/topup/topup_done_page.dart';

CardBrand topUp(String key) =>
    CardBrand.fromJson(fixtureTopUpBrands.firstWhere((b) => b['key'] == key));

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Types [text] one key at a time, as a thumb does.
Future<void> typeSlowly(WidgetTester tester, Finder field, String text) async {
  for (var i = 1; i <= text.length; i++) {
    await tester.enterText(field, text.substring(0, i));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The fixture relay with the top-ups on its shelf, telling [sent] what each
/// request carried.
http.Client recordingRelay(List<http.Request> sent) {
  final relay = fixtureRelay(topUps: true);
  return MockClient((request) {
    sent.add(request);
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..body = request.body;
    return relay.send(copy).then(http.Response.fromStream);
  });
}

void main() {
  group('an account is read the way the relay reads it', () {
    final freeFire = topUp('tu-free-fire').target!;
    final telegram = topUp('tg-stars').target!;
    final gift = topUp('sg-palworld').target!;
    final steam = topUp('steam-topup').target!;

    test('an Arabic keyboard\'s digits and stray spaces', () {
      final field = freeFire.fields.single;
      expect(freeFire.clean(field, ' ٥١٢٣ ٤٥٦ ٧٨٩ '), '5123456789');
      expect(freeFire.problemWith(field, ''), AccountProblem.required);
      expect(freeFire.checkable, isTrue);
    });

    test('a Telegram username from an @, a t.me link or a mistake', () {
      final field = telegram.fields.single;
      expect(telegram.clean(field, '@daftar_ly'), 'daftar_ly');
      expect(telegram.clean(field, 'https://t.me/daftar_ly'), 'daftar_ly');
      expect(telegram.problemWith(field, 'daftar_ly'), isNull);
      expect(telegram.problemWith(field, '9abc'), AccountProblem.notTelegram);
      expect(telegram.line({'username': 'daftar_ly'}), '@daftar_ly');
      expect(telegram.checkable, isFalse);
    });

    test('a Steam invite link cut out of what was pasted round it', () {
      final field = gift.fields.single;
      final clean = gift.clean(
        field,
        'Add me on Steam https://s.team/p/GKCP-MVN/CWQDTMJF thanks',
      );
      expect(clean, 'https://s.team/p/gkcp-mvn/CWQDTMJF');
      expect(gift.problemWith(field, clean), isNull);
      expect(
        gift.problemWith(field, 'steamcommunity.com/id/x'),
        AccountProblem.notInvite,
      );
    });

    test('a Steam login is one word, and can be looked up', () {
      final field = steam.fields.single;
      expect(steam.problemWith(field, 'gaben'), isNull);
      expect(steam.problemWith(field, 'ga-ben'), AccountProblem.notSteamLogin);
      expect(steam.checkable, isTrue);
    });
  });

  test('a card sent to an account this build cannot ask for is left off', () {
    final catalog = CardCatalog.fromJson({
      ...fixtureCatalogWithTopUps,
      'brands': [
        ...fixtureTopUpBrands,
        {
          ...fixtureTopUpBrands.first,
          'key': 'tu-future',
          'target': {
            'kind': 'email_address',
            'fields': [
              {'key': 'email', 'label': 'البريد'},
            ],
          },
        },
      ],
    });
    expect(catalog.brand('tu-free-fire')?.toAccount, isTrue);
    expect(catalog.brand('tu-future'), isNull);
  });

  test(
    'saved accounts: latest first, a name kept, taken back in place',
    () async {
      final accounts = SavedAccounts();
      await accounts.remember('ff', {'player_id': '1'}, name: 'Ahmed');
      await accounts.remember('ff', {'player_id': '2'});
      await accounts.remember('ff', {'player_id': '1'});
      var list = await accounts.of('ff');
      expect([for (final a in list) a.values['player_id']], ['1', '2']);
      expect(list.first.name, 'Ahmed');

      final second = list[1];
      await accounts.forget('ff', second.values);
      await accounts.restore('ff', second, at: 1);
      list = await accounts.of('ff');
      expect([for (final a in list) a.values['player_id']], ['1', '2']);

      await accounts.clear();
      expect(await accounts.of('ff'), isEmpty);
    },
  );

  testWidgets('a typed ID names its player, and the bar says where it goes', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(topUps: true),
        home: BrandPage(brand: topUp('tu-free-fire')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('حساب اللاعب'), findsOneWidget);
    expect(find.text('اختر الكمية'), findsOneWidget);
    expect(find.text('أدخل المعرّف'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '٥١٢٣٤٥٦٧٨٩');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('5123456789'), findsOneWidget);
    expect(find.text('اللاعب: \u2068ShadowFox_LY\u2069'), findsOneWidget);
    expect(find.text('إلى \u2068ShadowFox_LY\u2069'), findsOneWidget);
    // One top-up goes to one account at a time: there is no quantity.
    expect(find.text('اشحن'), findsOneWidget);
    expect(find.text('كرت واحد'), findsNothing);
  });

  testWidgets('an ID the game does not know is never paid for', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(topUps: true),
        home: BrandPage(brand: topUp('tu-free-fire')),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing typed: «اشحن» asks for the ID instead of opening checkout.
    await tester.tap(find.text('اشحن'));
    await tester.pumpAndSettle();
    expect(find.text('أدخل معرّف اللاعب (ID)'), findsOneWidget);
    expect(find.byType(CheckoutSheet), findsNothing);

    const notFound = 'لا يوجد حساب بهذا المعرّف. تأكد منه في ملفك داخل اللعبة.';
    // A pause while typing looks the ID up, but says nothing bad yet.
    await typeSlowly(tester, find.byType(TextField), '0001112223');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(notFound), findsNothing);
    expect(find.byIcon(Icons.cancel_rounded), findsNothing);

    // Done on the keyboard: now it says so, in the field and under it.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text(notFound), findsOneWidget);
    expect(find.byIcon(Icons.cancel_rounded), findsOneWidget);

    // Typing again takes it back while the new ID is typed.
    await typeSlowly(tester, find.byType(TextField), '00011122234');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(notFound), findsNothing);

    // «اشحن» never goes on with it: it shows why instead.
    await tester.tap(find.text('اشحن'));
    await tester.pumpAndSettle();
    expect(find.text(notFound), findsOneWidget);
    expect(find.byType(CheckoutSheet), findsNothing);
  });

  testWidgets('a pasted ID is looked up at once, and its answer shown', (
    tester,
  ) async {
    await phone(tester);
    final sent = <http.Request>[];
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(client: recordingRelay(sent)),
        home: BrandPage(brand: topUp('tu-free-fire')),
      ),
    );
    await tester.pumpAndSettle();
    // No pause to wait out: a paste is a whole ID.
    await tester.enterText(find.byType(TextField), '0001112223');
    await tester.pump();
    expect(
      sent.where((r) => r.url.path == '/v1/customers/accounts/check'),
      hasLength(1),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('لا يوجد حساب بهذا المعرّف. تأكد منه في ملفك داخل اللعبة.'),
      findsOneWidget,
    );
  });

  testWidgets('a saved account is looked up as its page opens', (tester) async {
    await phone(tester);
    final sent = <http.Request>[];
    final dependencies = fixtureDependencies(client: recordingRelay(sent));
    await dependencies.accounts.remember('tu-free-fire', {
      'player_id': '5123456789',
    }, name: 'ShadowFox_LY');
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: BrandPage(brand: topUp('tu-free-fire')),
      ),
    );
    await tester.pumpAndSettle();
    final checks = sent
        .where((r) => r.url.path == '/v1/customers/accounts/check')
        .toList();
    expect(checks, hasLength(1));
    expect(jsonDecode(checks.single.body)['account'], {
      'player_id': '5123456789',
    });
  });

  testWidgets('an ID pasted with its zone fills both fields', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(topUps: true),
        home: BrandPage(brand: topUp('tu-mlbb')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '123456789 (4567)');
    await tester.pumpAndSettle();
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect([for (final f in fields) f.controller!.text], ['123456789', '4567']);
    expect(find.text('إلى \u2066123456789 · 4567\u2069'), findsOneWidget);
  });

  testWidgets('a returning player picks their account from a list', (
    tester,
  ) async {
    await phone(tester);
    final dependencies = fixtureDependencies(topUps: true);
    await dependencies.accounts.remember('tu-free-fire', {
      'player_id': '7788990011',
    }, name: 'Noor.FF');
    await dependencies.accounts.remember('tu-free-fire', {
      'player_id': '5123456789',
    }, name: 'ShadowFox_LY');
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: BrandPage(brand: topUp('tu-free-fire')),
      ),
    );
    await tester.pumpAndSettle();

    // The latest is chosen; nothing to type.
    expect(find.text('ShadowFox_LY'), findsOneWidget);
    expect(find.text('Noor.FF'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('إلى \u2068ShadowFox_LY\u2069'), findsOneWidget);

    await tester.tap(find.text('Noor.FF'));
    await tester.pumpAndSettle();
    expect(find.text('إلى \u2068Noor.FF\u2069'), findsOneWidget);

    // «حساب آخر» opens the fields, empty.
    await tester.tap(find.text('حساب آخر'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('أدخل المعرّف'), findsOneWidget);

    // Swiped away, then taken back.
    await tester.drag(find.text('Noor.FF'), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Noor.FF'), findsNothing);
    expect(find.text('تراجع'), findsOneWidget);
    await tester.tap(find.text('تراجع'));
    await tester.pumpAndSettle();
    expect(find.text('Noor.FF'), findsOneWidget);
  });

  testWidgets('checkout names the account, sends it, and keeps it', (
    tester,
  ) async {
    await phone(tester);
    final sent = <http.Request>[];
    final dependencies = fixtureDependencies(client: recordingRelay(sent));
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: BrandPage(brand: topUp('tu-free-fire')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '5123456789');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('اشحن'));
    await tester.pumpAndSettle();

    expect(find.byType(CheckoutSheet), findsOneWidget);
    expect(find.text('إلى'), findsOneWidget);
    expect(find.text('5123456789'), findsWidgets);
    expect(find.textContaining('ShadowFox_LY'), findsWidgets);
    // The brand page's look-up is not asked again.
    expect(
      sent.where((r) => r.url.path == '/v1/customers/accounts/check'),
      hasLength(1),
    );

    await tester.tap(find.textContaining('ادفع'));
    await tester.pumpAndSettle();
    final order = sent.lastWhere(
      (r) => r.method == 'POST' && r.url.path == '/v1/customers/orders',
    );
    final body = jsonDecode(order.body) as Map<String, dynamic>;
    expect(body['account'], {'player_id': '5123456789'});
    expect(body['quantity'], 1);
    final saved = await dependencies.accounts.of('tu-free-fire');
    expect(saved.single.name, 'ShadowFox_LY');
  });

  testWidgets('a top-up that lands turns into its receipt', (tester) async {
    await phone(tester);
    final dependencies = fixtureDependencies(topUps: true);
    final watcher = OrderWatcher(
      orders: dependencies.orders,
      vault: dependencies.vault,
      order: CardOrder.fromJson(fixtureTopUpOrder(status: 'fulfilling')),
    );
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: OrderProgressPage(watcher: watcher, brand: topUp('tu-free-fire')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('نشحن الحساب…'), findsOneWidget);
    expect(find.text('5123456789'), findsOneWidget);

    watcher.start();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(TopUpDonePage), findsOneWidget);
    expect(find.text('تمّ الشحن'), findsOneWidget);
    expect(find.text('معرّف اللاعب (ID)'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('اشحن مجدداً'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('اشحن مجدداً'), findsOneWidget);
    // The watcher stops: a top-up has no code to wait for.
    expect(watcher.settled, isTrue);
    await tester.pumpWidget(const SizedBox());
    watcher.dispose();
  });

  testWidgets('«كروتي» lists a top-up as done, and opens its receipt', (
    tester,
  ) async {
    await phone(tester);
    final dependencies = fixtureDependencies(topUps: true);
    await dependencies.catalog.refresh();
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: const Scaffold(body: MyCardsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('تمّ الشحن'), findsOneWidget);
    expect(find.textContaining('إلى \u20665123456789\u2069'), findsOneWidget);

    await tester.tap(find.text('فري فاير · 520 جوهرة'));
    await tester.pumpAndSettle();
    expect(find.byType(TopUpDonePage), findsOneWidget);
    expect(find.text('5123456789'), findsOneWidget);
  });

  testWidgets('a Steam gift of one edition asks only for the account', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(topUps: true),
        home: BrandPage(brand: topUp('sg-palworld')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('حساب ستيم'), findsOneWidget);
    expect(find.text('اختر الإصدار'), findsNothing);
    expect(find.text('لصق'), findsOneWidget);
    expect(find.text('الصق رابط الدعوة'), findsOneWidget);
  });

  testWidgets('a top-up the store build lists for the website asks nothing', (
    tester,
  ) async {
    await phone(tester);
    final brand = CardBrand.fromJson({
      ...fixtureTopUpBrands.first,
      'web_only': true,
    });
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(topUps: true),
        home: BrandPage(brand: brand),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('اختر الكمية'), findsOneWidget);
  });
}
