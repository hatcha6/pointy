import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';

void main() {
  group('VariantCostSummary', () {
    test('parses a cost-summary row', () {
      final summary = VariantCostSummary.fromJson(const {
        'product': 4,
        'variant': 9,
        'variant_name': 'Large',
        'unit_price': '12.50',
        'lowest_cost': '2.00',
        'highest_cost': '4.00',
        'last_cost': '3.00',
        'average_cost': '3.00',
        'purchases_count': 3,
      });

      expect(summary.productId, 4);
      expect(summary.variantId, 9);
      expect(summary.variantName, 'Large');
      expect(summary.unitPrice, 12.50);
      expect(summary.lowestCost, 2.00);
      expect(summary.highestCost, 4.00);
      expect(summary.lastCost, 3.00);
      expect(summary.averageCost, 3.00);
      expect(summary.purchasesCount, 3);
      expect(summary.hasCost, isTrue);
    });

    test('leaves costs null and hasCost false when never purchased', () {
      final summary = VariantCostSummary.fromJson(const {
        'product': 1,
        'variant': 2,
        'variant_name': 'Default',
        'unit_price': '5.00',
        'purchases_count': 0,
      });

      expect(summary.lowestCost, isNull);
      expect(summary.highestCost, isNull);
      expect(summary.lastCost, isNull);
      expect(summary.averageCost, isNull);
      expect(summary.hasCost, isFalse);
    });

    test('listFromAny reads a bare list', () {
      final list = VariantCostSummary.listFromAny([
        const {'variant': 1, 'unit_price': '1.00', 'purchases_count': 0},
        const {'variant': 2, 'unit_price': '2.00', 'purchases_count': 1},
      ]);
      expect(list, hasLength(2));
      expect(list[1].variantId, 2);
    });
  });

  group('ProductQuery supplier filter', () {
    test('emits the supplier query parameter when set', () {
      const query = ProductQuery(supplierId: 7, supplierName: 'Acme');
      final params = query.toQueryParameters(page: 1);
      expect(params['supplier'], '7');
    });

    test('omits the supplier parameter when unset', () {
      const query = ProductQuery();
      expect(query.toQueryParameters(page: 1).containsKey('supplier'), isFalse);
    });

    test('withSupplier can clear the filter (copyWith preserves it)', () {
      const query = ProductQuery(supplierId: 7, supplierName: 'Acme');
      final cleared = query.withSupplier(supplierId: null, supplierName: null);
      expect(cleared.supplierId, isNull);
      // copyWith preserves the existing supplier, so it can't clear it.
      expect(query.copyWith().supplierId, 7);
    });
  });
}
