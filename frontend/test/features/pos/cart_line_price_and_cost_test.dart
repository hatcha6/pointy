import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/modifier_group.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';

/// Two rights a shop grants separately, and the line that carries one of them.
///
/// A cashier haggling at the counter needs to know the floor and to be able to
/// agree a number, without walking to the products screen — which would change
/// the price for every customer, not this one.
void main() {
  ProductVariant variant({double unitPrice = 10}) => ProductVariant(
    id: 7,
    productId: 1,
    sku: 'RICE-1',
    unitPrice: unitPrice,
    productName: 'أرز',
    displayName: 'أرز',
    fullName: 'أرز',
    isDefault: true,
  );

  CartLine line({
    double unitPrice = 10,
    double? manualUnitPrice,
    double? unitPriceOverride,
    List<CartLineModifier> modifiers = const [],
  }) => CartLine.create(
    variant: variant(unitPrice: unitPrice),
    quantity: 1,
    manualUnitPrice: manualUnitPrice,
    unitPriceOverride: unitPriceOverride,
    modifiers: modifiers,
  );

  group('a repriced line', () {
    test('sells at what the cashier typed', () {
      expect(line(manualUnitPrice: 6.5).unitPrice, 6.5);
    });

    test('still remembers what it would have sold for', () {
      // Shown beside the badge on the row, because "changed" without "from
      // what" is not something a manager can check afterwards.
      final repriced = line(manualUnitPrice: 6.5);

      expect(repriced.listUnitPrice, 10);
      expect(repriced.isRepriced, isTrue);
    });

    test('replaces the whole per-unit price, modifiers included', () {
      // The number the cashier edited was the one on the row, with modifiers
      // already folded in. Re-adding a delta on top would charge more than the
      // screen said.
      final withExtras = line(
        manualUnitPrice: 6.5,
        modifiers: const [
          CartLineModifier(
            optionId: 1,
            groupId: 1,
            groupName: 'حجم',
            optionName: 'كبير',
            priceDelta: 2,
            quantity: 1,
          ),
        ],
      );

      expect(withExtras.unitPrice, 6.5);
      expect(withExtras.listUnitPrice, 12);
    });

    test('is distinct from the price of a chosen unit', () {
      // unitPriceOverride is arithmetic — a carton costing 24x a piece — and
      // was here first. Conflating the two would make a unit switch look like
      // a cashier's decision.
      final carton = line(unitPriceOverride: 15);

      expect(carton.isRepriced, isFalse);
      expect(carton.unitPrice, 15);
    });

    test('survives being held and restored', () {
      // A held invoice keeps the price agreed with the customer; restoring it
      // at the shelf price would quietly change the deal.
      final restored = CartLine.fromJson(line(manualUnitPrice: 6.5).toJson());

      expect(restored.manualUnitPrice, 6.5);
      expect(restored.unitPrice, 6.5);
    });
  });

  group('what reaches the server', () {
    test('an ordinary line sends no price at all', () {
      // Everything is priced server-side precisely so a till cannot assert a
      // margin. A line that sends nothing is a line that cannot.
      final draft = SaleCheckoutLineDraft(variantId: 7, quantity: 1);

      expect(draft.toJson().containsKey('unit_price'), isFalse);
    });

    test('a repriced line sends the typed price', () {
      final draft = SaleCheckoutLineDraft(
        variantId: 7,
        quantity: 1,
        manualUnitPrice: 6.5,
      );

      expect(draft.toJson()['unit_price'], '6.50');
    });

    test('the discount preview carries it too', () {
      // Otherwise the cashier sees one total while typing and another on the
      // payment screen, which is the kind of disagreement that makes a till
      // untrustworthy.
      final draft = SaleDiscountPreviewDraft.fromCart(
        cart: [line(manualUnitPrice: 6.5)],
      );

      expect(draft.lines.single.manualUnitPrice, 6.5);
      expect(draft.toJson(), isNotNull);
    });
  });
}
