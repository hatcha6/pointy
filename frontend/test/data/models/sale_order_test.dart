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
}
