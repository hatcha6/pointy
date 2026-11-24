import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/features/checkout/checkout_model.dart';

void main() {
  test('credit first, then the fee on what Dafa collects', () async {
    final dependencies = fixtureDependencies();
    final brand = CardBrand.fromJson(
      (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
    );
    final model = CheckoutModel(
      orders: dependencies.orders,
      brand: brand,
      item: brand.items[1],
      quantity: 2,
    );
    await model.load();

    expect(model.credit, Money.parse('10'));
    expect(model.total, Money.parse('20'));
    expect(model.creditApplied, Money.parse('10'));
    expect(model.fee.toWire(), '0.210');
    expect(model.toPay.toWire(), '10.210');
    expect(model.method?.key, 'dafa_moamalat');

    model.setUseCredit(false);
    expect(model.toPay.toWire(), '20.410');

    model
      ..setUseCredit(true)
      ..setQuantity(1);
    expect(model.creditCovers, isTrue);
    expect(model.fee, Money.zero);
    expect(model.needsPayerDetails, isFalse);
  });

  test('an offer comes off the order before credit and the fee, and only '
      'once the order reaches its minimum', () async {
    final dependencies = fixtureDependencies(offers: [fixtureOffer]);
    final brand = CardBrand.fromJson(
      (fixtureCatalog['brands'] as List).first as Map<String, dynamic>,
    );
    final model = CheckoutModel(
      orders: dependencies.orders,
      brand: brand,
      item: brand.items[1],
      quantity: 1,
    );
    await model.load();

    // 10 dinars: below the 15 the offer asks for.
    expect(model.subtotal, Money.parse('10'));
    expect(model.offer, isNull);
    expect(model.discount, Money.zero);
    expect(model.coveringOffers.single.id, 'offer-1');

    // 20 dinars: 20% is 4.
    model.setQuantity(2);
    expect(model.offer?.id, 'offer-1');
    expect(model.discount, Money.parse('4'));
    expect(model.total, Money.parse('16'));
    // Credit pays what is left after it.
    expect(model.creditApplied, Money.parse('10'));
    expect(model.due, Money.parse('6'));

    // 40 dinars: capped at 5.
    model.setQuantity(4);
    expect(model.discount, Money.parse('5'));

    model.setUseOffer(false);
    expect(model.discount, Money.zero);
    expect(model.total, Money.parse('40'));
    expect(model.availableOffer?.id, 'offer-1');
  });
}
