import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';
import 'package:pointy_cards/src/core/result.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/bundle/bundle_page.dart';
import 'package:pointy_cards/src/features/checkout/checkout_model.dart';
import 'package:pointy_cards/src/features/reveal/reveal_page.dart';

CardCatalog _shelf({
  Map<String, dynamic> bundle = fixtureBundle,
  bool pubgSold = true,
}) {
  final json =
      jsonDecode(jsonEncode(fixtureCatalogWithTopUps)) as Map<String, dynamic>;
  json['bundles'] = [bundle];
  if (!pubgSold) {
    for (final brand in json['brands'] as List) {
      if (brand['key'] == 'pubg') {
        for (final item in brand['items'] as List) {
          if (item['key'] == 'pubg-60') {
            item['available'] = false;
          }
        }
      }
    }
  }
  return CardCatalog.fromJson(json);
}

void main() {
  group('a bundle on the shelf', () {
    test('is priced from its cards less its saving, per network', () {
      final bundle = _shelf().shelfBundles.single;
      expect(bundle.name, 'باقة اللاعب');
      // The network part is the one the buyer picks in.
      expect(bundle.choices.keys, [1]);
      expect(bundle.choices[1]!.map((b) => b.key), ['libyana', 'almadar']);
      expect(bundle.defaultPick, ['pubg', 'libyana']);

      final small = bundle.tier('gamer-60')!;
      // PUBG 60 at 5.50 and 5 dinars of credit, less 0.50.
      expect(small.apart(bundle.defaultPick), Money.parse('10.50'));
      expect(small.price(bundle.defaultPick), Money.parse('10.00'));
      expect(small.cards(['pubg', 'almadar']).map((c) => c.item.key), [
        'pubg-60',
        'almadar-5',
      ]);
      expect(small.label(['pubg', 'almadar']), '60 شدة + 5 دينار');
      expect(bundle.bestSaving, Money.parse('1.25'));
      expect(bundle.fromPrice, Money.parse('10.00'));
    });

    test('stands in as a brand, so every page draws and sells it', () {
      final shelf = _shelf();
      final brand = shelf.brand('bundle:gamer')!;
      expect(brand.isBundle, isTrue);
      expect(brand.items.map((i) => i.key), ['gamer-60', 'gamer-325']);
      expect(brand.items.first.regularPrice, Money.parse('10.50'));
    });

    test('takes the artwork for the network picked', () {
      final bundle = _shelf(
        bundle: {
          ...fixtureBundle,
          'art': {'libyana': 'sha256:aa', 'almadar': 'sha256:bb'},
        },
      ).shelfBundles.single;
      expect(bundle.asBrand().logo, 'sha256:aa');
      expect(bundle.asBrand(['pubg', 'almadar']).logo, 'sha256:bb');
    });

    test('drops a size missing a card, and is gone with none left', () {
      final shelf = _shelf(pubgSold: false);
      expect(shelf.shelfBundles.single.tiers.map((t) => t.tier.key), [
        'gamer-325',
      ]);
      final none = _shelf(
        bundle: {
          ...fixtureBundle,
          'tiers': [
            {
              'key': 'gamer-x',
              'saving': '0.500',
              'parts': [
                ['tu-free-fire-100'], // sent to an account: never bundled
                ['libyana-5'],
              ],
            },
          ],
        },
      );
      expect(none.shelfBundles, isEmpty);
      expect(none.brand('bundle:gamer'), isNull);
    });

    test('is never sold at or under nothing', () {
      final shelf = _shelf(
        bundle: {
          ...fixtureBundle,
          'tiers': [
            {
              'key': 'gamer-free',
              'saving': '10.500',
              'parts': [
                ['pubg-60'],
                ['libyana-5'],
              ],
            },
          ],
        },
      );
      expect(shelf.shelfBundles, isEmpty);
    });
  });

  test(
    'a bundle is ordered with its cards, without a quote or an offer',
    () async {
      final sent = <Map<String, dynamic>>[];
      final asked = <String>[];
      final fixture = fixtureRelay(offers: fixtureOffers);
      final client = MockClient((request) async {
        asked.add(request.url.path);
        if (request.method == 'POST' &&
            request.url.path == '/v1/customers/orders') {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return fixture.send(copy).then(http.Response.fromStream);
      });
      final bundle = _shelf().shelfBundles.single;
      final pick = ['pubg', 'almadar'];
      final tier = bundle.tier('gamer-325')!;
      final model = CheckoutModel(
        orders: fixtureDependencies(client: client).orders,
        brand: bundle.asBrand(pick),
        item: tier.asItem(pick),
        bundleItems: [for (final card in tier.cards(pick)) card.item.key],
      );
      await model.load();
      expect(asked, isNot(contains('/v1/customers/me/quote')));
      expect(model.offer, isNull);
      // 325 UC at 27.00 and 10 dinars, less 1.25.
      expect(model.total, Money.parse('35.75'));
      model.useCredit = false;
      await model.pay();
      expect(sent.single['item'], 'gamer-325');
      expect(sent.single['bundle_items'], ['pubg-325', 'almadar-10']);
      expect(sent.single['unit_price'], '35.750');
      expect(sent.single.containsKey('offer_id'), isFalse);
      expect(sent.single.containsKey('quote'), isFalse);
      model.dispose();
    },
  );

  testWidgets('a bundle\'s codes each show as their own card', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dependencies = fixtureDependencies(topUps: true);
    await tester.runAsync(dependencies.catalog.refresh);
    final order = CardOrder.fromJson({
      ...fixtureOrder(
        item: 'gamer-325',
        brand: 'bundle:gamer',
        name: 'باقة اللاعب · 325 شدة + 10 دينار',
      ),
      'codes': [
        {'code': '5A2F-91KD-PQ7X', 'brand': 'pubg', 'item': 'pubg-325'},
        {
          'code': '4827 1930 5561 2208',
          'brand': 'almadar',
          'item': 'almadar-10',
        },
      ],
    });
    expect(order.codes.map((c) => c.brandKey), ['pubg', 'almadar']);
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: RevealPage(order: order),
      ),
    );
    await tester.pumpAndSettle();
    // The first card is PUBG's, with PUBG's way to redeem it.
    expect(find.text('ببجي موبايل'), findsWidgets);
    expect(find.text('المدار'), findsNothing);

    await tester.fling(find.byType(PageView), const Offset(400, 0), 1500);
    await tester.pumpAndSettle();
    // Then the network's own card.
    expect(find.text('المدار'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  test('a bought bundle shows the network it was bought for, on the shelf '
      'or off it', () async {
    final dependencies = fixtureDependencies(topUps: true);
    await dependencies.catalog.refresh();
    final order = CardOrder.fromJson(fixtureBundleOrder);
    final brand = dependencies.catalog.brandOfOrder(order)!;
    expect(brand.isBundle, isTrue);
    expect(brand.name, 'باقة اللاعب');

    // Taken off the shelf: still its name and its first card's art.
    final gone = fixtureDependencies();
    await gone.catalog.refresh();
    final kept = gone.catalog.brandOfOrder(order)!;
    expect(kept.name, 'باقة اللاعب');
    expect(kept.isBundle, isTrue);
  });

  test('which network a bought bundle was for picks its artwork', () {
    final shelf = _shelf(
      bundle: {
        ...fixtureBundle,
        'art': {'libyana': 'sha256:aa', 'almadar': 'sha256:bb'},
      },
    );
    final bundle = shelf.shelfBundles.single;
    expect(bundle.asBrand(['pubg', 'almadar']).logo, 'sha256:bb');
  });

  test('a bundle delivered without one card says so, and counts the rest', () {
    final order = CardOrder.fromJson(fixturePartlyRefundedBundleOrder);
    expect(order.partlyRefunded, isTrue);
    expect(order.bundleRefunded, ['libyana-10']);
    expect(order.refunded, Money.parse('10.00'));
    expect(order.cardCount, 1);
    final whole = CardOrder.fromJson(fixtureBundleOrder);
    expect(whole.partlyRefunded, isFalse);
    expect(whole.cardCount, 2);
  });

  testWidgets('the reveal names the card that was refunded and the credit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dependencies = fixtureDependencies(topUps: true);
    await tester.runAsync(dependencies.catalog.refresh);
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: RevealPage(
          order: CardOrder.fromJson(fixturePartlyRefundedBundleOrder),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('تعذّر شراء ليبيانا · 10 دينار'), findsOneWidget);
    expect(find.textContaining('10.00'), findsWidgets);
    // One card left: no pager.
    expect(find.byType(PageView), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  group('a network a size does not have', () {
    final bundle = _shelf(
      bundle: {
        ...fixtureBundle,
        'tiers': [
          {
            'key': 'gamer-60',
            'saving': '0.500',
            'parts': [
              ['pubg-60'],
              ['libyana-5', 'almadar-5'],
            ],
          },
          {
            'key': 'gamer-325',
            'saving': '1.250',
            'parts': [
              ['pubg-325'],
              ['libyana-10'],
            ],
          },
        ],
      },
    ).shelfBundles.single;

    test('is never quietly swapped for another network', () {
      final big = bundle.tier('gamer-325')!;
      expect(bundle.offers(big, ['pubg', 'libyana']), isTrue);
      expect(bundle.offers(big, ['pubg', 'almadar']), isFalse);
      // The nearest size that has it instead.
      expect(
        bundle.nearestOffering(big, ['pubg', 'almadar'])?.tier.key,
        'gamer-60',
      );
    });

    test('is still offered when any size has it', () {
      expect(bundle.choices[1]!.map((b) => b.key), ['libyana', 'almadar']);
    });
  });

  testWidgets('a bundle reached as a brand opens its own page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dependencies = fixtureDependencies(topUps: true);
    await tester.runAsync(dependencies.catalog.refresh);
    final brand = dependencies.catalog.brandOf('bundle:gamer')!;
    await tester.pumpWidget(
      CardsApp(
        dependencies: dependencies,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => BrandPage.open(context, brand),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(BundlePage), findsOneWidget);
    expect(find.byType(BrandPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('the shelf is asked for as the signed-in customer, and unsigned '
      'when the token is refused', () async {
    final asked = <String?>[];
    final fixture = fixtureRelay();
    final client = MockClient((request) async {
      if (request.url.path == '/v1/customers/catalog') {
        final auth = request.headers['Authorization'];
        asked.add(auth);
        if (auth != null && asked.length == 2) {
          return http.Response('{"code":"token_expired"}', 401);
        }
      }
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      return fixture.send(copy).then(http.Response.fromStream);
    });
    final dependencies = fixtureDependencies(client: client);
    expect(await dependencies.catalog.refresh(), isA<Ok<CardCatalog>>());
    expect(asked.single, startsWith('Bearer '));
    // A token the relay will not take: asked again, unsigned.
    expect(await dependencies.catalog.refresh(), isA<Ok<CardCatalog>>());
    expect(asked.sublist(1), [startsWith('Bearer '), isNull]);
  });
}
