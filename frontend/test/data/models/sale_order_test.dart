import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';

void main() {
  group('the preview prices the lines checkout will sell', () {
    // Field report, 2026-09-25: a 45-dinar LNET top-up sat in the cart at 45
    // while the net total read 0.00. The preview left the top-up behind, so
    // the server priced the provider's service product at its standing zero;
    // the payment sheet asked for nothing and checkout refused the tender.
    final topUp = CartLine.create(
      variant: const ProductVariant(
        id: 1698,
        productId: 1220,
        sku: 'INTEG-LNET',
        unitPrice: 45,
        isService: true,
      ),
      quantity: 1,
      integration: const CartLineIntegration(
        provider: 'lnet',
        subscriberRef: 'alhussainbasheir',
        optionCode: 'topup:45',
        optionLabel: '45 د.ل',
        cost: 42.75,
      ),
    );
    final handset = CartLine.create(
      variant: const ProductVariant(
        id: 990,
        productId: 990,
        sku: '2864',
        unitPrice: 160,
      ),
      quantity: 1,
      stockUnitId: 77,
      stockUnitCode: '356789012345678',
    );

    Map<String, Object?> previewLine(CartLine line) {
      final json = SaleDiscountPreviewDraft.fromCart(cart: [line]).toJson();
      return (json['lines']! as List).single as Map<String, Object?>;
    }

    Map<String, Object?> checkoutLine(CartLine line) {
      final json = SaleCheckoutDraft.fromCart(
        cart: [line],
        payments: const [],
      ).toJson();
      return (json['lines']! as List).single as Map<String, Object?>;
    }

    test('a top-up travels with its line', () {
      final line = previewLine(topUp);

      expect(line['integration'], topUp.integration!.toJson());
      expect(line['integration'], checkoutLine(topUp)['integration']);
    });

    test('a serialized line names its article, which may carry its price', () {
      expect(previewLine(handset)['stock_units'], [77]);
      expect(
        previewLine(handset)['stock_units'],
        checkoutLine(handset)['stock_units'],
      );
    });

    test('an ordinary line stays exactly as it was', () {
      final plain = CartLine.create(
        variant: const ProductVariant(
          id: 5,
          productId: 5,
          sku: 'CABLE',
          unitPrice: 20,
        ),
        quantity: 2,
      );

      expect(previewLine(plain), {'variant': 5, 'quantity': '2'});
    });
  });

  group('SaleLossLine.fromJson', () {
    test('accepts whole-number quantities encoded as decimal values', () {
      final line = SaleLossLine.fromJson(const {
        'variant_name': 'قميص',
        'quantity': '8.000',
        'unit_price': '4.00',
        'unit_cost': '5.00',
        'line_total': '32.00',
        'line_cost': '40.00',
        'loss_amount': '8.00',
      });

      expect(line.productName, 'قميص');
      expect(line.quantity, 8);
      expect(line.lossAmount, 8);
    });

    test('falls back instead of throwing when quantity is malformed', () {
      final line = SaleLossLine.fromJson(const {
        'product_name': 'منتج',
        'quantity': 'غير صالح',
        'unit_price': '4.00',
        'unit_cost': '5.00',
        'line_total': '32.00',
        'line_cost': '40.00',
        'loss_amount': '8.00',
      });

      expect(line.quantity, 0);
    });
  });

  group('the cashier\'s own discount on the wire', () {
    SaleCheckoutLineDraft line() =>
        const SaleCheckoutLineDraft(variantId: 1, quantity: 1);

    test('checkout sends the amount the cashier typed', () {
      final json = SaleCheckoutDraft(
        lines: [line()],
        payments: const [],
        extraDiscountAmount: 7.5,
      ).toJson();

      expect(json['extra_discount_amount'], '7.50');
    });

    test('an ordinary sale does not mention it at all', () {
      // Absent, not "0.00": an older backend reads a key it does not know as a
      // field error, and every sale that was never haggled over is this one.
      final json = SaleCheckoutDraft(
        lines: [line()],
        payments: const [],
      ).toJson();

      expect(json.containsKey('extra_discount_amount'), isFalse);
    });

    test('the preview asks on the same terms checkout will charge', () {
      final json = SaleDiscountPreviewDraft(
        lines: [line()],
        extraDiscountAmount: 3,
      ).toJson();

      expect(json['extra_discount_amount'], '3.00');
    });

    test('the preview reads back what was applied and what would fit', () {
      final preview = SaleDiscountPreview.fromJson(const {
        'subtotal': '12.00',
        'discount_total': '12.00',
        'total': '0.00',
        'extra_discount_amount': '12.00',
        'max_extra_discount_amount': '12.00',
      });

      // The cashier typed 50 against a 12 cart; 12 is what the sale is getting
      // and 12 is what the panel must show.
      expect(preview.extraDiscountAmount, 12);
      expect(preview.maxExtraDiscountAmount, 12);
      expect(preview.total, 0);
    });

    test('an older backend that says nothing leaves it at zero', () {
      final preview = SaleDiscountPreview.fromJson(const {
        'subtotal': '12.00',
        'discount_total': '0.00',
        'total': '12.00',
      });

      expect(preview.extraDiscountAmount, 0);
      expect(preview.maxExtraDiscountAmount, 0);
    });

    test('an invoice reports the discount its cashier gave', () {
      final order = SaleOrder.fromJson(const {
        'id': 1,
        'status': 'paid',
        'lines': <Object?>[],
        'payments': <Object?>[],
        'subtotal': '15.00',
        'discount_total': '3.00',
        'extra_discount_amount': '3.00',
        'total': '12.00',
      });

      expect(order.extraDiscountAmount, 3);
      expect(order.discountTotal, 3);
    });
  });
}
