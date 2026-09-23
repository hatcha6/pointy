import 'product_variant.dart';

/// A single counted item within a stock count session.
///
/// The lightweight payload (from `count` and the session detail) carries only
/// quantities and flags; the reconciliation payload also embeds [variant] so the
/// finish screen can render the product name, unit, and image.
class StockCountLine {
  const StockCountLine({
    required this.id,
    required this.stockCountId,
    required this.variantId,
    required this.countedQuantity,
    required this.expectedQuantity,
    required this.variance,
    required this.needsReview,
    required this.applied,
    required this.staleAtApply,
    this.onHandAtApply,
    this.countedAt,
    this.movementId,
    this.variant,
  });

  final int id;
  final int stockCountId;
  final int variantId;
  final double countedQuantity;

  /// On-hand snapshot captured when this line was counted. Shown only on
  /// reconciliation — never on the blind counting screen.
  final double expectedQuantity;
  final double variance;
  final bool needsReview;
  final bool applied;

  /// Whether stock moved between counting this line and applying the count.
  /// Recorded at apply time for the audit trail; not surfaced in the UI.
  final bool staleAtApply;
  final double? onHandAtApply;
  final DateTime? countedAt;
  final int? movementId;
  final ProductVariant? variant;

  bool get hasVariance => countedQuantity != expectedQuantity;

  factory StockCountLine.fromJson(Map<String, Object?> json) {
    final variantDetail = json['variant_detail'];
    return StockCountLine(
      id: _intFromJson(json['id']),
      stockCountId: _intFromJson(json['stock_count']),
      variantId: _intFromJson(json['variant']),
      countedQuantity: _doubleFromJson(json['counted_quantity']),
      expectedQuantity: _doubleFromJson(json['expected_quantity']),
      variance: _doubleFromJson(json['variance']),
      needsReview: json['needs_review'] == true,
      applied: json['applied'] == true,
      staleAtApply: json['stale_at_apply'] == true,
      onHandAtApply: json['on_hand_at_apply'] == null
          ? null
          : _doubleFromJson(json['on_hand_at_apply']),
      countedAt: _dateTimeFromJson(json['counted_at']),
      movementId: json['movement'] == null
          ? null
          : _intFromJson(json['movement']),
      variant: variantDetail is Map<String, Object?>
          ? ProductVariant.fromJson(variantDetail)
          : null,
    );
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

double _doubleFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
