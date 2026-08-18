import 'query.dart';
import 'sale_order.dart';

class SaleOrderPage {
  const SaleOrderPage({
    required this.orders,
    required this.hasMore,
    this.nextCursor,
  });

  final List<SaleOrder> orders;
  final bool hasMore;

  /// Opaque keyset cursor for the following page, set only by the endpoints
  /// that paginate by cursor (a register session's sales). Null elsewhere.
  final String? nextCursor;

  factory SaleOrderPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(SaleOrder.fromJson)
        .toList(growable: false);

    return SaleOrderPage(
      orders: results,
      hasMore: json['next'] != null,
      nextCursor: nextPageCursor(json['next']),
    );
  }

  factory SaleOrderPage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      return SaleOrderPage.fromJson(decoded);
    }
    if (decoded is List<Object?>) {
      return SaleOrderPage(
        orders: decoded
            .whereType<Map<String, Object?>>()
            .map(SaleOrder.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const SaleOrderPage(orders: [], hasMore: false);
  }
}
