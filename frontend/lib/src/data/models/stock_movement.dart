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
  final int quantity;
  final String note;
  final String? createdByName;
  final int onHandBefore;
  final int onHandAfter;
  final int committedBefore;
  final int committedAfter;
  final int expectedBefore;
  final int expectedAfter;
  final DateTime? createdAt;

  factory StockMovement.fromJson(Map<String, Object?> json) {
    return StockMovement(
      id: json['id'] as int,
      product: json['product'] as int,
      movementType: StockMovementType.fromJson(json['movement_type']),
      quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      note: json['note']?.toString() ?? '',
      createdByName: json['created_by_name']?.toString(),
      onHandBefore: (json['on_hand_before'] as num?)?.toInt() ?? 0,
      onHandAfter: (json['on_hand_after'] as num?)?.toInt() ?? 0,
      committedBefore: (json['committed_before'] as num?)?.toInt() ?? 0,
      committedAfter: (json['committed_after'] as num?)?.toInt() ?? 0,
      expectedBefore: (json['expected_before'] as num?)?.toInt() ?? 0,
      expectedAfter: (json['expected_after'] as num?)?.toInt() ?? 0,
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class StockMovementDraft {
  const StockMovementDraft({
    required this.product,
    required this.movementType,
    required this.quantity,
    this.note = '',
  });

  final int product;
  final StockMovementType movementType;
  final int quantity;
  final String note;

  Map<String, Object?> toJson() {
    return {
      'product': product,
      'movement_type': movementType.apiValue,
      'quantity': quantity,
      'note': note,
    };
  }
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
