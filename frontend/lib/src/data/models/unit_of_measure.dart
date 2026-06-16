/// A unit a product can be counted, sold, or purchased in — mirrors the backend
/// `catalog.UnitOfMeasure` registry. Packaging units (box, carton) have no global
/// `referenceFactor`; physical units (kg, g) carry one so the UI can suggest a
/// predictable per-product factor when they share the base unit's dimension.
class UnitOfMeasure {
  const UnitOfMeasure({
    required this.id,
    required this.code,
    required this.name,
    this.abbreviation = '',
    this.dimension = 'count',
    this.referenceFactor,
    this.allowsFractional = false,
    this.isSystem = false,
    this.isActive = true,
    this.displayOrder = 0,
    this.productCount = 0,
  });

  final int id;
  final String code;
  final String name;
  final String abbreviation;
  final String dimension;
  final double? referenceFactor;
  final bool allowsFractional;
  final bool isSystem;
  final bool isActive;
  final int displayOrder;

  /// How many products use this unit (read-only; from the backend annotation).
  final int productCount;

  bool get isInUse => productCount > 0;

  /// A built-in unit cannot be deleted (only deactivated) and its code is locked.
  bool get isDeletable => !isSystem && !isInUse;

  /// Short label for chips and receipts; falls back to the full name, then code.
  String get label {
    if (abbreviation.trim().isNotEmpty) return abbreviation.trim();
    if (name.trim().isNotEmpty) return name.trim();
    return code;
  }

  factory UnitOfMeasure.fromJson(Map<String, Object?> json) {
    return UnitOfMeasure(
      id: _intFromJson(json['id']),
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      abbreviation: json['abbreviation']?.toString() ?? '',
      dimension: json['dimension']?.toString() ?? 'count',
      referenceFactor: _doubleOrNull(json['reference_factor']),
      allowsFractional: json['allows_fractional'] == true,
      isSystem: json['is_system'] == true,
      isActive: (json['is_active'] as bool?) ?? true,
      displayOrder: _intFromJson(json['display_order']),
      productCount: _intFromJson(json['product_count']),
    );
  }
}

/// The known measurement dimensions a unit can belong to (mirrors the backend
/// `UnitDimension` choices). Units only convert within their dimension.
const List<String> kUnitDimensions = ['count', 'weight', 'volume', 'length'];

/// Write payload for creating/updating a [UnitOfMeasure].
class UnitOfMeasureDraft {
  const UnitOfMeasureDraft({
    required this.code,
    required this.name,
    this.abbreviation = '',
    this.dimension = 'count',
    this.referenceFactor,
    this.allowsFractional = false,
    this.isActive = true,
    this.displayOrder = 0,
    this.includeCode = true,
  });

  final String code;
  final String name;
  final String abbreviation;
  final String dimension;
  final double? referenceFactor;
  final bool allowsFractional;
  final bool isActive;
  final int displayOrder;

  /// System units lock their code server-side, so editing one omits `code`.
  final bool includeCode;

  Map<String, Object?> toJson() {
    return {
      if (includeCode) 'code': code,
      'name': name,
      'abbreviation': abbreviation,
      'dimension': dimension,
      'reference_factor': referenceFactor,
      'allows_fractional': allowsFractional,
      'is_active': isActive,
      'display_order': displayOrder,
    };
  }
}

int _intFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

double? _doubleOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}
