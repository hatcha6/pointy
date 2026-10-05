/// One product variant whose units on the shelf are still owed a lot.
///
/// `serial → serial_batch` keeps the units already on the shelf with no lot
/// (§4.2): they still sell, but no recall can find them. The worklist names
/// them a variant at a time, because a lot belongs to one variant.
class MissingLotGroup {
  const MissingLotGroup({
    required this.variantId,
    required this.productId,
    required this.productName,
    required this.count,
    this.variantName = '',
    this.sku = '',
    this.expiryRequired = false,
  });

  factory MissingLotGroup.fromJson(Map<String, Object?> json) {
    return MissingLotGroup(
      variantId: _int(json['variant']),
      productId: _int(json['product']),
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      sku: json['sku']?.toString() ?? '',
      count: _int(json['count']),
      expiryRequired: json['expiry_required'] == true,
    );
  }

  final int variantId;
  final int productId;
  final String productName;
  final String variantName;
  final String sku;
  final int count;

  /// A new lot of this product must say when it expires, as at receiving.
  final bool expiryRequired;

  /// The product, then the variant when it has a name of its own.
  String get title {
    final variant = variantName.trim();
    return variant.isEmpty ? productName : '$productName - $variant';
  }

  MissingLotGroup withCount(int next) => MissingLotGroup(
    variantId: variantId,
    productId: productId,
    productName: productName,
    variantName: variantName,
    sku: sku,
    count: next,
    expiryRequired: expiryRequired,
  );
}

/// The lot the units went into: an existing one, or one created from the
/// code typed off the box.
class LotAssignment {
  const LotAssignment({
    required this.batchId,
    required this.batchCode,
    required this.created,
    required this.assigned,
  });

  factory LotAssignment.fromJson(Map<String, Object?> json) {
    return LotAssignment(
      batchId: _int(json['batch']),
      batchCode: json['batch_code']?.toString() ?? '',
      created: json['created'] == true,
      assigned: _int(json['assigned']),
    );
  }

  final int batchId;
  final String batchCode;
  final bool created;
  final int assigned;
}

/// Which lot the chosen units go into — one the variant has, or a new code.
class LotChoice {
  const LotChoice.existing(int this.batchId, {this.label = ''})
    : code = '',
      expiryDate = null;

  const LotChoice.create(this.code, {this.expiryDate})
    : batchId = null,
      label = '';

  final int? batchId;

  /// How an existing lot reads in a confirmation.
  final String label;
  final String code;
  final DateTime? expiryDate;

  bool get isNew => batchId == null;

  String get displayCode => isNew ? code : label;

  Map<String, Object?> toJson() {
    if (batchId case final id?) {
      return {'batch': id};
    }
    return {
      'lot_code': code,
      if (expiryDate case final date?) 'expiry_date': _isoDate(date),
    };
  }
}

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? '').toString()) ?? 0;
}
