import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/stock_batch.dart';

/// The server removes a cost it will not show a reader rather than blanking
/// it, so a client must read "absent" as "not told" — never as a cost of 0,
/// which a later screen would happily print.
void main() {
  test("a lot's cost is not told to a cashier, and is not zero either", () {
    final hidden = StockBatchBalance.fromJson({
      'id': 1,
      'batch': 1,
      'warehouse': 5,
      'remaining_quantity': '10.000',
    });
    final shown = StockBatchBalance.fromJson({
      'id': 1,
      'batch': 1,
      'warehouse': 5,
      'remaining_quantity': '10.000',
      'incoming_rate': '14.000000',
    });

    expect(hidden.incomingRate, isNull);
    expect(hidden.remainingQuantity, 10);
    expect(shown.incomingRate, 14);
  });

  test("a part's cost is not told to the counter, and is not zero either", () {
    Map<String, Object?> material({String? unitCost}) => {
      'id': 3,
      'variant': 9,
      'product_name': 'شاشة آيفون',
      'variant_name': '',
      'quantity': '1.000',
      'unit_cost': ?unitCost,
      'unit_price': '120.00',
      'line_total': '120.00',
      'is_consumed': true,
    };

    expect(JobMaterial.fromJson(material()).unitCost, isNull);
    expect(JobMaterial.fromJson(material()).unitPrice, 120);
    expect(JobMaterial.fromJson(material(unitCost: '80.00')).unitCost, 80);
  });
}
