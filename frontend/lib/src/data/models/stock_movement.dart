import 'sale_order.dart' show formatQuantityForApi;

enum StockMovementType {
  increase('increase'),
  decrease('decrease'),
  damaged('damaged');

  const StockMovementType(this.apiValue);

  final String apiValue;

  static StockMovementType fromJson(Object? value) {
    final text = value?.toString();
    return StockMovementType.values.firstWhere(
      (type) => type.apiValue == text,
      orElse: () => StockMovementType.increase,
    );
  }
}

class StockMovement {
  const StockMovement({
    required this.id,
    required this.product,
    required this.movementType,
    required this.quantity,
    required this.onHandBefore,
    required this.onHandAfter,
    required this.committedBefore,
    required this.committedAfter,
    required this.expectedBefore,
    required this.expectedAfter,
    this.note = '',
    this.createdByName,
    this.createdAt,
  });

  final int id;
  final int product;
  final StockMovementType movementType;
  final double quantity;
  final String note;
  final String? createdByName;
  final double onHandBefore;
  final double onHandAfter;
  final double committedBefore;
  final double committedAfter;
  final double expectedBefore;
  final double expectedAfter;
  final DateTime? createdAt;

  factory StockMovement.fromJson(Map<String, Object?> json) {
    return StockMovement(
      id: json['id'] as int,
      product: json['product'] as int,
      movementType: StockMovementType.fromJson(json['movement_type']),
      quantity: _quantityFromJson(json['quantity']),
      note: json['note']?.toString() ?? '',
      createdByName: json['created_by_name']?.toString(),
      onHandBefore: _quantityFromJson(json['on_hand_before']),
      onHandAfter: _quantityFromJson(json['on_hand_after']),
      committedBefore: _quantityFromJson(json['committed_before']),
      committedAfter: _quantityFromJson(json['committed_after']),
      expectedBefore: _quantityFromJson(json['expected_before']),
      expectedAfter: _quantityFromJson(json['expected_after']),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class StockMovementDraft {
  const StockMovementDraft({
    required this.variant,
    required this.movementType,
    required this.quantity,
    this.note = '',
  });

  final int variant;
  final StockMovementType movementType;
  final double quantity;
  final String note;

  Map<String, Object?> toJson() {
    return {
      'variant': variant,
      'movement_type': movementType.apiValue,
      'quantity': formatQuantityForApi(quantity),
      'note': note,
    };
  }
}

double _quantityFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
