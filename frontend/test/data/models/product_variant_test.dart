import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/variant_option_value.dart';

void main() {
  group('Product variant fallback ids', () {
    test(
      'product variant id stays null when no default variant is present',
      () {
        const product = Product(id: 9, name: 'قميص', quantityOnHand: 0);

        expect(product.variantId, isNull);
      },
    );

    test('product variant id uses the default variant when present', () {
      const product = Product(
        id: 9,
        name: 'قميص',
        quantityOnHand: 0,
        defaultVariant: ProductVariant(
          id: 27,
          productId: 9,
          sku: 'SHIRT-RED-L',
          unitPrice: 12,
        ),
      );

      expect(product.variantId, 27);
    });
  });

  group('Product variant labels', () {
    test('blank explicit names fall back to option values', () {
      const variant = ProductVariant(
        id: 1,
        productId: 9,
        productName: 'قميص',
        name: ' ',
        displayName: 'قميص',
        fullName: 'قميص',
        sku: 'SHIRT-RED-L',
        unitPrice: 12,
        optionValues: [
          VariantOptionValue(
            id: 11,
            optionId: 1,
            optionName: 'اللون',
            name: 'أحمر',
          ),
          VariantOptionValue(
            id: 12,
            optionId: 2,
            optionName: 'المقاس',
            name: 'كبير',
          ),
        ],
      );

      expect(variant.productLabel, 'قميص');
      expect(variant.variantLabel, 'اللون: أحمر / المقاس: كبير');
      expect(variant.pickerLabel, 'اللون: أحمر / المقاس: كبير');
      expect(variant.displayLabel, 'قميص - اللون: أحمر / المقاس: كبير');
    });

    test('option values keep blank-name sibling variants distinct', () {
      const redVariant = ProductVariant(
        id: 1,
        productId: 9,
        productName: 'قميص',
        displayName: 'قميص',
        fullName: 'قميص',
        sku: 'SHIRT-RED',
        unitPrice: 12,
        optionValues: [
          VariantOptionValue(
            id: 11,
            optionId: 1,
            optionName: 'اللون',
            name: 'أحمر',
          ),
        ],
      );
      const blueVariant = ProductVariant(
        id: 2,
        productId: 9,
        productName: 'قميص',
        displayName: 'قميص',
        fullName: 'قميص',
        sku: 'SHIRT-BLUE',
        unitPrice: 12,
        optionValues: [
          VariantOptionValue(
            id: 12,
            optionId: 1,
            optionName: 'اللون',
            name: 'أزرق',
          ),
        ],
      );

      expect(redVariant.pickerLabel, 'اللون: أحمر');
      expect(blueVariant.pickerLabel, 'اللون: أزرق');
      expect(redVariant.displayLabel, isNot(blueVariant.displayLabel));
    });
  });

  group('Foreign-priced variants', () {
    // A catalog-list row as the server sends it: each variant carries its
    // `price_amount` but no `product_detail`, and the currency it is written
    // in rides on the product alone.
    Map<String, Object?> variantJson() => {
      'id': 27,
      'product': 9,
      'sku': 'HEADSET',
      'unit_price': '82.20',
      'price_amount': '12.00',
      'is_default': true,
    };
    Map<String, Object?> dollarRow() => {
      'id': 9,
      'name': 'سماعة',
      'pricing_currency': 'USD',
      'default_variant': variantJson(),
      'variants': [variantJson()],
    };

    test('a catalog row keeps its foreign price once re-attached', () {
      final product = Product.fromJson(dollarRow());

      for (final variant in [product.defaultVariant!, ...product.variants]) {
        expect(variant.productDetail, isNotNull);
        expect(variant.priceAmount, 12);
        expect(variant.pricingCurrency, 'USD');
        expect(variant.hasForeignPrice, isTrue);
        expect(variant.unitPrice, 82.2, reason: 'the dinar shelf price');
      }
    });

    test('a copy keeps the foreign price', () {
      final copy = Product.fromJson(
        dollarRow(),
      ).defaultVariant!.copyWith(quantityOnHand: 3);

      expect(copy.priceAmount, 12);
      expect(copy.pricingCurrency, 'USD');
      expect(copy.hasForeignPrice, isTrue);
    });
  });
}
