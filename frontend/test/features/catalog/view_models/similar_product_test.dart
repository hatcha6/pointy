import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/modifier_group.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/models/variant_option.dart';
import 'package:pointy_frontend/src/data/models/variant_option_value.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/similar_product.dart';

/// «منتج مشابه» copies what describes a product and nothing that identifies
/// it: two products sharing a barcode is a scan that rings up the wrong one.
void main() {
  const carton = UnitOfMeasure(id: 2, code: 'carton', name: 'كرتون');

  Product cola({
    double unitPrice = 1.25,
    String pricingCurrency = '',
    double? priceAmount,
  }) {
    return Product(
      id: 1,
      name: 'كولا علبة 330',
      quantityOnHand: 40,
      description: 'مشروب غازي',
      tracksExpiry: true,
      pricingCurrency: pricingCurrency,
      defaultSaleUnit: 'carton',
      categories: const [
        ProductCategory(id: 3, name: 'مشروبات', parentName: 'بقالة'),
      ],
      modifierGroups: const [ModifierGroup(id: 9, name: 'ثلج')],
      units: const [
        ProductUnit(
          id: 70,
          unit: carton,
          factorToBase: 24,
          price: 30,
          barcodes: ['6281000000999'],
        ),
      ],
      defaultVariant: ProductVariant(
        id: 11,
        productId: 1,
        sku: '1001',
        barcode: '6281000000013',
        unitPrice: unitPrice,
        priceAmount: priceAmount,
        isDefault: true,
      ),
    );
  }

  test('a product gives what describes it and none of its codes', () {
    final similar = SimilarProduct.of(cola());

    expect(similar.sourceName, 'كولا علبة 330');
    expect(similar.carried.name, 'كولا علبة 330');
    expect(similar.carried.price, '1.25');
    expect(similar.carried.pricingCurrency, '');
    expect([for (final c in similar.carried.categories) c.id], [3]);
    expect(similar.carried.unit, 'piece');
    expect(similar.carried.tracksExpiry, isTrue);
    expect(similar.carried.openingCost, '', reason: "the original's shelf");
    expect(similar.description, 'مشروب غازي');
    expect(similar.modifierGroupIds, {9});
    expect(similar.defaultSaleUnit, 'carton');
    expect(similar.fillsMoreDetails, isTrue);
    expect(similar.hasVariantGrid, isFalse);

    // Boxed the same way — but the carton's barcode is the original's.
    final unit = similar.units.single;
    expect(unit.code, 'carton');
    expect(unit.factorToBase, 24);
    expect(unit.price, 30);
    expect(unit.barcodes, isEmpty);
    expect(unit.id, isNull, reason: 'a new row, not the original one');
  });

  test('a price is copied exactly, in the currency it was written in', () {
    expect(SimilarProduct.of(cola(unitPrice: 0.125)).carried.price, '0.125');
    expect(SimilarProduct.of(cola(unitPrice: 3)).carried.price, '3');

    final dollars = SimilarProduct.of(
      cola(unitPrice: 84.25, pricingCurrency: 'USD', priceAmount: 12.5),
    );
    expect(dollars.carried.price, '12.5');
    expect(dollars.carried.pricingCurrency, 'USD');
  });

  test('a foreign price survives the catalog payload', () {
    // As the list sends it: the currency on the product, the dollar figure on
    // a variant that arrives without its product.
    final source = Product.fromJson(const {
      'id': 1,
      'name': 'كولا علبة 330',
      'pricing_currency': 'USD',
      'default_variant': {
        'id': 11,
        'product': 1,
        'sku': '1001',
        'unit_price': '84.25',
        'price_amount': '12.50',
        'is_default': true,
      },
    });

    final similar = SimilarProduct.of(source);
    expect(similar.carried.price, '12.5');
    expect(similar.carried.pricingCurrency, 'USD');
  });

  test("a sized and coloured product brings its grid, row by row", () {
    VariantOptionValue value(int id, int optionId, String name) =>
        VariantOptionValue(id: id, optionId: optionId, name: name);
    final small = value(11, 1, 'S');
    final medium = value(12, 1, 'M');
    final red = value(21, 2, 'أحمر');
    final blue = value(22, 2, 'أزرق');
    ProductVariant variant(
      int id,
      List<VariantOptionValue> values, {
      required double price,
      bool isActive = true,
      bool isDefault = false,
    }) {
      return ProductVariant(
        id: id,
        productId: 5,
        sku: 'SHIRT-$id',
        barcode: '62800$id',
        unitPrice: price,
        isActive: isActive,
        isDefault: isDefault,
        optionValueIds: [for (final value in values) value.id],
        optionValues: values,
      );
    }

    final smallRed = variant(101, [small, red], price: 10, isDefault: true);
    final similar = SimilarProduct.of(
      Product(
        id: 5,
        name: 'قميص قطن',
        quantityOnHand: 0,
        // The payload may name the options without listing their values; the
        // variants' own values say which option each belongs to.
        variantOptions: const [
          VariantOption(id: 1, code: 'size', name: 'المقاس'),
          VariantOption(id: 2, code: 'color', name: 'اللون'),
        ],
        defaultVariant: smallRed,
        variants: [
          smallRed,
          variant(102, [medium, red], price: 12),
          // Listed colour first: a signature must not care about the order.
          variant(103, [blue, small], price: 10, isActive: false),
        ],
      ),
    );

    expect(similar.hasVariantGrid, isTrue);
    expect(similar.variantOptionIds, {1, 2});
    expect(similar.valueIdsByOption, {
      1: {11, 12},
      2: {21, 22},
    });
    expect(similar.rowsBySignature, {
      '11|21': (price: '10', isActive: true),
      '12|21': (price: '12', isActive: true),
      '11|22': (price: '10', isActive: false),
    });
    expect(similar.defaultSignature, '11|21');
    expect(similar.carried.price, '10', reason: 'the default row prices it');
  });

  test('an option no variant was made in is not copied', () {
    final similar = SimilarProduct.of(
      const Product(
        id: 6,
        name: 'شاي',
        quantityOnHand: 0,
        variantOptions: [VariantOption(id: 1, code: 'size', name: 'المقاس')],
        defaultVariant: ProductVariant(
          id: 61,
          productId: 6,
          sku: '1006',
          unitPrice: 5,
          isDefault: true,
        ),
      ),
    );

    expect(similar.hasVariantGrid, isFalse);
    expect(similar.carried.price, '5');
  });
}
