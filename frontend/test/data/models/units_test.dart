import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';

ProductVariant _variant({double price = 1.0}) {
  return ProductVariant(
    id: 1,
    productId: 7,
    sku: 'SKU',
    unitPrice: price,
    unit: 'piece',
  );
}

void main() {
  group('Product unit parsing', () {
    test('parses units, defaults, and resolves derived price', () {
      final product = Product.fromJson({
        'id': 7,
        'name': 'Soda',
        'unit': 'piece',
        'default_sale_unit': 'box',
        'default_purchase_unit': 'carton',
        'units': [
          {
            'id': 3,
            'unit': 'box',
            'unit_detail': {
              'id': 9,
              'code': 'box',
              'name': 'صندوق',
              'abbreviation': 'صندوق',
              'allows_fractional': false,
            },
            'factor_to_base': '12',
            'price': null,
            'is_sellable': true,
            'is_purchasable': true,
          },
        ],
        'quantity_on_hand': 0,
      });

      expect(product.defaultSaleUnit, 'box');
      expect(product.defaultPurchaseUnit, 'carton');
      expect(product.units, hasLength(1));
      final box = product.units.single;
      expect(box.code, 'box');
      expect(box.factorToBase, 12);
      expect(box.allowsFractional, isFalse);
      // Null custom price derives from base price × factor.
      expect(box.resolvedPrice(1.5), 18);
      expect(product.hasSellableUnits, isTrue);
    });

    test('custom price overrides the derived price', () {
      const unit = ProductUnit(
        unit: UnitOfMeasure(id: 1, code: 'box', name: 'صندوق'),
        factorToBase: 12,
        price: 10,
      );
      expect(unit.resolvedPrice(1.5), 10);
    });
  });

  group('CartLine units', () {
    test('base unit line prices off the variant', () {
      final line = CartLine.create(variant: _variant(price: 2), quantity: 3);
      expect(line.isBaseUnit, isTrue);
      expect(line.unitPrice, 2);
      expect(line.total, 6);
      expect(line.baseQuantity, 3);
    });

    test('non-base unit uses the override price and converts to base', () {
      final line = CartLine.create(
        variant: _variant(price: 2),
        quantity: 2,
        unitCode: 'box',
        unitLabel: 'صندوق',
        unitFactor: 12,
        unitPriceOverride: 20,
      );
      expect(line.isBaseUnit, isFalse);
      expect(line.unitPrice, 20);
      expect(line.total, 40);
      expect(line.baseQuantity, 24);
    });

    test('copyWith can clear the override back to the base unit', () {
      final line = CartLine.create(
        variant: _variant(price: 2),
        quantity: 1,
        unitCode: 'box',
        unitFactor: 12,
        unitPriceOverride: 20,
      );
      final reset = line.copyWith(
        unitCode: '',
        unitFactor: 1,
        unitPriceOverride: null,
      );
      expect(reset.unitPrice, 2);
      expect(reset.isBaseUnit, isTrue);
    });
  });

  group('Draft serialization', () {
    test('checkout line includes the unit code when set', () {
      const withUnit = SaleCheckoutLineDraft(
        variantId: 1,
        quantity: 2,
        unit: 'box',
      );
      expect(withUnit.toJson()['unit'], 'box');

      const base = SaleCheckoutLineDraft(variantId: 1, quantity: 2);
      expect(base.toJson().containsKey('unit'), isFalse);
    });

    test('purchase line includes the unit code when set', () {
      const withUnit = PurchaseOrderLineDraft(
        variantId: 1,
        quantity: 3,
        unitCost: 48,
        unit: 'carton',
      );
      expect(withUnit.toJson()['unit'], 'carton');

      const base = PurchaseOrderLineDraft(
        variantId: 1,
        quantity: 3,
        unitCost: 1,
      );
      expect(base.toJson().containsKey('unit'), isFalse);
    });

    test('product unit serializes factor and optional price', () {
      const unit = ProductUnit(
        unit: UnitOfMeasure(id: 1, code: 'box', name: 'صندوق'),
        factorToBase: 6,
        price: 5,
      );
      final json = unit.toJson();
      expect(json['unit'], 'box');
      expect(json['factor_to_base'], '6.0');
      expect(json['price'], '5.00');
    });
  });

  group('UnitOfMeasure management', () {
    test('parses product_count and derives delete eligibility', () {
      final custom = UnitOfMeasure.fromJson({
        'id': 9,
        'code': 'box',
        'name': 'صندوق',
        'dimension': 'count',
        'is_system': false,
        'product_count': 0,
      });
      expect(custom.isInUse, isFalse);
      expect(custom.isDeletable, isTrue);

      final inUseSystem = UnitOfMeasure.fromJson({
        'id': 1,
        'code': 'kg',
        'name': 'كيلوغرام',
        'dimension': 'weight',
        'is_system': true,
        'product_count': 3,
      });
      expect(inUseSystem.isInUse, isTrue);
      expect(inUseSystem.isDeletable, isFalse);
    });

    test('draft omits the code for system units, includes it otherwise', () {
      const custom = UnitOfMeasureDraft(code: 'box', name: 'صندوق');
      expect(custom.toJson()['code'], 'box');

      const system = UnitOfMeasureDraft(
        code: 'kg',
        name: 'كيلوغرام',
        includeCode: false,
      );
      expect(system.toJson().containsKey('code'), isFalse);
      expect(system.toJson()['name'], 'كيلوغرام');
      // reference_factor is always present (null clears it server-side).
      expect(system.toJson().containsKey('reference_factor'), isTrue);
    });
  });

  group('Order line unit labels', () {
    test('sale order line reads the transacted unit and label', () {
      final line = SaleOrderLine.fromJson({
        'id': 1,
        'product': 7,
        'variant': 3,
        'quantity': '2',
        'returned_quantity': '0',
        'returnable_quantity': '2',
        'unit': 'box',
        'unit_label': 'صندوق',
        'unit_price': '12.00',
        'line_total': '24.00',
      });
      expect(line.unit, 'box');
      expect(line.unitLabel, 'صندوق');
    });
  });
}
