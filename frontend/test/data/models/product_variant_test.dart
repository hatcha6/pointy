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
}
