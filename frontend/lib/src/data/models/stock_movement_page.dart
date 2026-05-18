import 'stock_movement.dart';

class StockMovementPage {
  const StockMovementPage({required this.movements, required this.hasMore});

  final List<StockMovement> movements;
  final bool hasMore;

  factory StockMovementPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(StockMovement.fromJson)
        .toList(growable: false);

    return StockMovementPage(movements: results, hasMore: json['next'] != null);
  }
}
