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
}
