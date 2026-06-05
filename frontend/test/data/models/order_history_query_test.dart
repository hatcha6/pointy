import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';

void main() {
  test('sale order query includes invoice filters and ordering', () {
    final query = const SaleOrderQuery(
      search: 'R2026',
      status: SaleOrderStatusFilter.paid,
      customerId: 3,
      productId: 9,
      variantId: 27,
      ordering: SaleOrderOrdering.totalDesc,
    ).toQueryParameters(page: 2);

    expect(query, {
      'search': 'R2026',
      'status': 'paid',
      'customer': '3',
      'product': '9',
      'variant': '27',
      'ordering': '-total',
      'page': '2',
    });
  });

  test('purchase order query includes product and variant filters', () {
    final query = const PurchaseOrderQuery(
      productId: 9,
      variantId: 27,
    ).toQueryParameters(page: 1);

    expect(query, {
      'product': '9',
      'variant': '27',
      'ordering': '-created_at',
      'page': '1',
    });
  });
}
