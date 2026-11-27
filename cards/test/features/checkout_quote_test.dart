import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/data/api/relay_api.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';
import 'package:pointy_cards/src/features/checkout/checkout_model.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// The fixture relay, with quotes and an order route that records what it
/// was sent and answers from [orderAnswers] in turn.
({http.Client client, List<Map<String, dynamic>> orders}) _relay({
  Map<String, dynamic>? quote,
  List<http.Response Function(Map<String, dynamic>)> orderAnswers = const [],
}) {
  final fixture = fixtureRelay();
  final sent = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'POST' && path == '/v1/customers/me/quote') {
      return quote == null
          ? _json({'code': 'not_found'}, 404)
          : _json({...quote, 'item': jsonDecode(request.body)['item']});
    }
    if (request.method == 'POST' && path == '/v1/customers/orders') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      sent.add(body);
      if (sent.length <= orderAnswers.length) {
        return orderAnswers[sent.length - 1](body);
      }
      return _json({
        'order': fixtureOrder(
          id: 'order-new',
          status: 'awaiting_payment',
          item: body['item'] as String,
          nextAction: 'hosted_page',
          method: 'dafa_moamalat',
        ),
      }, 201);
    }
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;
    return fixture.send(copy).then(http.Response.fromStream);
  });
  return (client: client, orders: sent);
}

CheckoutModel _checkout(http.Client client) {
  final brand = CardBrand.fromJson(
    (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
  );
  return CheckoutModel(
    orders: fixtureDependencies(client: client).orders,
    brand: brand,
    item: brand.items[1],
  );
}

String _expiresIn(Duration duration) =>
    DateTime.now().add(duration).toUtc().toIso8601String();

void main() {
  test('the checkout shows and sends the price the relay quotes, and says '
      'when it is not the shelf price', () async {
    final relay = _relay(
      quote: {
        'unit_price': '10.200',
        'quote': 'q-1',
        'expires_at': _expiresIn(const Duration(minutes: 10)),
      },
    );
    final model = _checkout(relay.client);
    expect(model.item.price, Money.parse('10'));
    await model.load();

    expect(model.unitPrice, Money.parse('10.2'));
    expect(model.total, Money.parse('10.2'));
    expect(model.priceMovedTo, Money.parse('10.2'));

    model.setUseCredit(false);
    await model.pay();
    expect(relay.orders.single['unit_price'], '10.200');
    expect(relay.orders.single['quote'], 'q-1');
    expect(model.order?.id, 'order-new');
    // Paid at it: nothing more to say.
    expect(model.priceMovedTo, isNull);
    model.dispose();
  });

  test('a price that rose past the quote is shown with the refusal, and the '
      'next tap is placed at it with the quote the refusal carried', () async {
    final relay = _relay(
      quote: {
        'unit_price': '10.000',
        'quote': 'q-1',
        'expires_at': _expiresIn(const Duration(minutes: 10)),
      },
      orderAnswers: [
        (_) => _json({
          'code': 'price_changed',
          'error': 'the price changed; check it and try again',
          'unit_price': '10.600',
          'quote': 'q-2',
          'quote_expires_at': _expiresIn(const Duration(minutes: 10)),
        }, 409),
      ],
    );
    final model = _checkout(relay.client);
    await model.load();
    expect(model.priceMovedTo, isNull, reason: 'the shelf price held');

    model.setUseCredit(false);
    expect(await model.pay(), isNull);
    expect((model.error as RelayApiException).code, 'price_changed');
    expect(model.unitPrice, Money.parse('10.6'));
    expect(model.total, Money.parse('10.6'));
    // The refusal says it; the notice does not say it twice.
    expect(model.priceMovedTo, isNull);

    await model.pay();
    expect(relay.orders, hasLength(2));
    expect(relay.orders.last['unit_price'], '10.600');
    expect(relay.orders.last['quote'], 'q-2');
    expect(
      relay.orders.last['idempotency_key'],
      isNot(relay.orders.first['idempotency_key']),
    );
    expect(model.order?.id, 'order-new');
    model.dispose();
  });

  test('a relay from before quotes: the shelf price, and a refusal\'s new '
      'price is the next one sent', () async {
    final relay = _relay(
      orderAnswers: [
        (_) => _json({
          'code': 'price_changed',
          'error': 'the price changed; check it and try again',
          'unit_price': '10.400',
        }, 409),
      ],
    );
    final model = _checkout(relay.client);
    await model.load();
    expect(model.unitPrice, Money.parse('10'));
    expect(model.quote, isNull);

    model.setUseCredit(false);
    await model.pay();
    expect(relay.orders.first.containsKey('quote'), isFalse);
    expect(relay.orders.first['unit_price'], '10.000');
    // Once stuck sending the stale shelf price at every tap.
    await model.pay();
    expect(relay.orders.last['unit_price'], '10.400');
    expect(model.order?.id, 'order-new');
    model.dispose();
  });

  testWidgets('the sheet says so when the quote is not the shelf price, '
      'before the customer taps', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final relay = _relay(
      quote: {
        'unit_price': '10.200',
        'quote': 'q-1',
        'expires_at': _expiresIn(const Duration(minutes: 10)),
      },
    );
    final brand = CardBrand.fromJson(
      (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
    );
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(client: relay.client),
        home: BrandPage(brand: brand),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 دينار'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('اشترِ'));
    await tester.pumpAndSettle();

    expect(find.textContaining('تغيّر السعر إلى 10.20'), findsOneWidget);
    // Closed, so its quote's refresh goes with it.
    await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await tester.pumpAndSettle();
  });
}
