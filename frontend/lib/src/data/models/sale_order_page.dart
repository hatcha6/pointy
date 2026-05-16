import 'sale_order.dart';

class SaleOrderPage {
  const SaleOrderPage({required this.orders, required this.hasMore});

  final List<SaleOrder> orders;
  final bool hasMore;

  factory SaleOrderPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(SaleOrder.fromJson)
        .toList(growable: false);

    return SaleOrderPage(orders: results, hasMore: json['next'] != null);
  }
}
