class StockItem {
  const StockItem({
    required this.id,
    required this.product,
    required this.quantityOnHand,
    required this.quantityCommitted,
    required this.quantityExpected,
    required this.reorderLevel,
  });

  final int id;
  final int product;
  final int quantityOnHand;
  final int quantityCommitted;
  final int quantityExpected;
  final int reorderLevel;

  factory StockItem.fromJson(Map<String, Object?> json) {
    return StockItem(
      id: json['id'] as int,
      product: json['product'] as int,
      quantityOnHand: (json['quantity_on_hand'] as num?)?.toInt() ?? 0,
      quantityCommitted: (json['quantity_committed'] as num?)?.toInt() ?? 0,
      quantityExpected: (json['quantity_expected'] as num?)?.toInt() ?? 0,
      reorderLevel: (json['reorder_level'] as num?)?.toInt() ?? 0,
    );
  }
}
