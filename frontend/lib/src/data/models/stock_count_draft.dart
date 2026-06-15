import 'stock_count.dart';

class StockCountStartDraft {
  const StockCountStartDraft({
    required this.scope,
    this.categoryId,
    this.note = '',
  });

  final StockCountScope scope;
  final int? categoryId;
  final String note;

  Map<String, Object?> toJson() {
    return {
      'scope': scope == StockCountScope.category ? 'category' : 'full',
      if (scope == StockCountScope.category && categoryId != null)
        'category': categoryId,
      if (note.trim().isNotEmpty) 'note': note.trim(),
    };
  }
}

enum StockCountEntryMode { add, replace }

class StockCountLineDraft {
  const StockCountLineDraft({
    required this.variantId,
    required this.countedQuantity,
    this.mode = StockCountEntryMode.replace,
  });

  final int variantId;
  final double countedQuantity;
  final StockCountEntryMode mode;

  Map<String, Object?> toJson() {
    return {
      'variant': variantId,
      // Sent as a string so the backend Decimal field never sees float noise.
      'counted_quantity': countedQuantity.toStringAsFixed(3),
      'mode': mode == StockCountEntryMode.add ? 'add' : 'replace',
    };
  }
}
