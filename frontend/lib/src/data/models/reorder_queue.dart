/// How urgently one variant needs buying. See `apps/purchasing/reorder.py`.
enum ReorderStatus {
  out,
  low,

  /// Above its threshold but about to cross it, going by its recent sales.
  approaching;

  static ReorderStatus fromJson(Object? value) => switch (value) {
    'out' => ReorderStatus.out,
    'low' => ReorderStatus.low,
    _ => ReorderStatus.approaching,
  };
}

class ReorderRow {
  const ReorderRow({
    required this.variantId,
    required this.productId,
    required this.productName,
    required this.status,
    required this.onHand,
    required this.threshold,
    required this.orderQuantity,
    this.variantName = '',
    this.sku = '',
    this.expected = 0,
    this.inDraft = 0,
    this.daysLeft,
    this.lastSupplierName = '',
  });

  factory ReorderRow.fromJson(Map<String, Object?> json) {
    return ReorderRow(
      variantId: json['variant'] as int,
      productId: json['product'] as int,
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      status: ReorderStatus.fromJson(json['status']),
      onHand: _quantity(json['on_hand']),
      threshold: _quantity(json['threshold']),
      expected: _quantity(json['expected']),
      inDraft: _quantity(json['in_draft']),
      daysLeft: json['days_left'] as int?,
      orderQuantity: _quantity(json['order_quantity']),
      lastSupplierName: json['last_supplier_name']?.toString() ?? '',
    );
  }

  final int variantId;
  final int productId;
  final String productName;

  /// Blank for a product's only variant.
  final String variantName;
  final String sku;
  final ReorderStatus status;
  final double onHand;
  final double threshold;

  /// On purchase orders already sent, in base units.
  final double expected;

  /// On drafts nobody has sent yet, so a buyer does not draft it twice.
  final double inDraft;

  /// Days of sales before the threshold; null with no sales to go by.
  final int? daysLeft;

  /// What the server suggests ordering, in base units. Never zero.
  final double orderQuantity;
  final String lastSupplierName;

  /// For the screen's own search: the queue is small and already here.
  bool matches(String term) {
    final needle = term.trim().toLowerCase();
    return needle.isEmpty ||
        productName.toLowerCase().contains(needle) ||
        variantName.toLowerCase().contains(needle) ||
        sku.toLowerCase().contains(needle);
  }

  static double _quantity(Object? value) =>
      double.tryParse(value?.toString() ?? '') ?? 0;
}

class ReorderQueue {
  const ReorderQueue({required this.rows, required this.totalCount});

  factory ReorderQueue.fromJson(Map<String, Object?> json) {
    final rows = (json['results'] as List<Object?>? ?? const [])
        .map((row) => ReorderRow.fromJson((row as Map).cast<String, Object?>()))
        .toList(growable: false);
    return ReorderQueue(
      rows: rows,
      totalCount: json['count'] as int? ?? rows.length,
    );
  }

  final List<ReorderRow> rows;

  /// How many rows there were before the server's cap; above [rows]' length,
  /// the screen says the rest are not shown.
  final int totalCount;
}

/// One ticked row: what to order, in the variant's base unit.
class ReorderOrderLine {
  const ReorderOrderLine({required this.variantId, required this.quantity});

  final int variantId;
  final double quantity;

  Map<String, Object?> toJson() => {
    'variant': variantId,
    'quantity': quantity.toStringAsFixed(3),
  };
}
