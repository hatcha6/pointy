import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';

void main() {
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
