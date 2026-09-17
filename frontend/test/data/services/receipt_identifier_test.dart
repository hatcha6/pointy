import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';

/// A receipt that does not name the IMEI cannot settle a warranty claim, and one
/// that does not name the lot cannot answer a recall. Both come off the sale's
/// own rows, so neither can drift from what actually left the shop.
void main() {
  group('a sale line\'s identifiers', () {
    test('a serialized line carries its own article', () {
      final line = SaleOrderLine.fromJson({
        'id': 1,
        'product': 2,
        'variant': 3,
        'quantity': '1',
        'returned_quantity': '0',
        'returnable_quantity': '1',
        'unit_price': '1500.00',
        'line_total': '1500.00',
        'identifiers': [
          {'kind': 'unit', 'code': '351234567890116', 'quantity': '1'},
        ],
      });

      expect(line.identifiers.single.isUnit, isTrue);
      expect(line.identifiers.single.code, '351234567890116');
    });

    test('a lot line names every cohort the pick drew from', () {
      final line = SaleOrderLine.fromJson({
        'id': 1,
        'product': 2,
        'variant': 3,
        'quantity': '4',
        'returned_quantity': '0',
        'returnable_quantity': '4',
        'unit_price': '20.00',
        'line_total': '80.00',
        'identifiers': [
          {
            'kind': 'batch',
            'code': 'SOON',
            'expiry_date': '2026-10-31',
            'quantity': '3.000',
          },
          {
            'kind': 'batch',
            'code': 'LATE',
            'expiry_date': '2027-08-31',
            'quantity': '1.000',
          },
        ],
      });

      expect(line.identifiers.length, 2);
      expect(line.identifiers.first.isUnit, isFalse);
      expect(line.identifiers.first.quantity, 3);
      expect(line.identifiers.last.expiryDate, DateTime(2027, 8, 31));
    });

    test('an ordinary line carries none, and reads exactly as it did', () {
      final line = SaleOrderLine.fromJson({
        'id': 1,
        'product': 2,
        'variant': 3,
        'quantity': '2',
        'returned_quantity': '0',
        'returnable_quantity': '2',
        'unit_price': '3.00',
        'line_total': '6.00',
      });

      expect(line.identifiers, isEmpty);
    });
  });
}
