import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/features/brand/brand_page.dart';

Map<String, dynamic> _item(
  String value,
  String currency,
  String price, {
  String country = '',
  int rank = 0,
}) => {
  'key': 'card-$value$currency$country',
  'country': country,
  'label':
      '$value ${currency == 'USD'
              ? 'دولار'
              : currency == 'EUR'
              ? 'يورو'
              : ''}'
          .trim(),
  'face_value': value,
  'face_currency': currency,
  'price': price,
  'regular_price': price,
  'available': true,
  'rank': rank,
};

CardBrand _brand(List<Map<String, dynamic>> items) => CardBrand.fromJson({
  'key': 'gc-rewarble',
  'name': 'ريواربل',
  'category': 'gift_cards',
  'items': items,
});

/// As the relay lists it: sold in no one country, dollars and euros mixed.
final _rewarble = _brand([
  _item('5', 'USD', '60.75'),
  _item('5', 'EUR', '67.00', rank: 1),
  _item('10', 'USD', '119.75', rank: 2),
  _item('10', 'EUR', '132.25', rank: 3),
]);

void main() {
  test('a card sold in several currencies and no one country is told apart '
      'by currency, and starts at the price of the first', () {
    expect(_rewarble.currencies, ['USD', 'EUR']);
    expect(
      _rewarble.fromPrice.toString(),
      _rewarble.items.first.price.toString(),
    );
  });

  test('cards told apart by country, or with a value in no currency, are '
      'not', () {
    expect(
      _brand([
        _item('10', 'USD', '60.00', country: 'AE'),
        _item('50', 'AED', '70.00', country: 'AE'),
      ]).currencies,
      isEmpty,
    );
    expect(
      _brand([_item('10', 'USD', '60.00'), _item('800', '', '70.00')])
          .currencies,
      isEmpty,
    );
    expect(
      _brand([_item('10', 'USD', '60.00'), _item('20', 'USD', '70.00')])
          .currencies,
      isEmpty,
    );
  });

  testWidgets('its page shows one currency at a time, chosen as a country '
      'is', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: BrandPage(brand: _rewarble),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('العملة'), findsOneWidget);
    expect(find.text('10 دولار'), findsOneWidget);
    expect(find.text('10 يورو'), findsNothing);

    await tester.tap(find.text('يورو'));
    await tester.pumpAndSettle();
    expect(find.text('10 يورو'), findsOneWidget);
    expect(find.text('10 دولار'), findsNothing);
  });

  testWidgets('opened on a euro card, it shows the euro ones', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(),
        home: BrandPage(brand: _rewarble, initialItem: _rewarble.items[3]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('5 يورو'), findsOneWidget);
    expect(find.text('5 دولار'), findsNothing);
  });
}
