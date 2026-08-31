import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_draft.dart';
import 'package:pointy_frontend/src/data/models/product_variant_draft.dart';

ProductDraft _draft({
  String currency = '',
  double? priceAmount,
  double unitPrice = 9.5,
  List<ProductVariantDraft> variants = const [],
}) => ProductDraft(
  name: 'Widget',
  variantSku: 'W-1',
  variantUnitPrice: unitPrice,
  isActive: true,
  tracksExpiry: false,
  pricingCurrency: currency,
  variantPriceAmount: priceAmount,
  variants: variants,
);

void main() {
  group('base-priced product', () {
    test('sends a null pricing currency rather than omitting it', () {
      // Omitting it would make switching a product BACK to the shop currency a
      // silent no-op on a PATCH.
      final json = _draft().toJson();
      expect(json.containsKey('pricing_currency'), isTrue);
      expect(json['pricing_currency'], isNull);
    });

    test('sends no foreign price', () {
      final variant = _draft().toJson()['default_variant'] as Map;
      expect(variant.containsKey('price_amount'), isFalse);
      expect(variant['unit_price'], '9.50');
    });
  });

  group('foreign-priced product', () {
    test('sends the currency and the foreign amount', () {
      final json = _draft(
        currency: 'USD',
        priceAmount: 12,
        unitPrice: 0,
      ).toJson();
      expect(json['pricing_currency'], 'USD');
      final variant = json['default_variant'] as Map;
      expect(variant['price_amount'], '12.00');
    });

    test('lets the server derive the base price rather than computing one', () {
      // The client never computes a stored price: one conversion, one place.
      final variant =
          _draft(
                currency: 'USD',
                priceAmount: 12,
                unitPrice: 0,
              ).toJson()['default_variant']
              as Map;
      expect(variant['unit_price'], '0.00');
    });
  });

  group('generated variants', () {
    test('each carries its own foreign amount', () {
      final json = _draft(
        currency: 'USD',
        variants: const [
          ProductVariantDraft(
            productId: 0,
            sku: 'W-S',
            unitPrice: 0,
            priceAmount: 5,
            isDefault: true,
          ),
          ProductVariantDraft(
            productId: 0,
            sku: 'W-L',
            unitPrice: 0,
            priceAmount: 8,
          ),
        ],
      ).toJson();
      final variants = json['variants'] as List;
      expect(variants, hasLength(2));
      expect((variants[0] as Map)['price_amount'], '5.00');
      expect((variants[1] as Map)['price_amount'], '8.00');
      // The nested default_variant is not sent alongside the generated list.
      expect(json.containsKey('default_variant'), isFalse);
    });

    test('a base-priced generated variant sends no foreign amount', () {
      const variant = ProductVariantDraft(
        productId: 0,
        sku: 'W-S',
        unitPrice: 4.25,
      );
      expect(variant.toJson().containsKey('price_amount'), isFalse);
    });
  });
}
