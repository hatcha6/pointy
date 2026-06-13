class BomLine {
  const BomLine({
    required this.id,
    required this.componentVariant,
    required this.componentName,
    required this.componentProductName,
    required this.quantity,
    this.componentUnit = 'piece',
    required this.wastePercent,
  });

  final int id;
  final int componentVariant;
  final String componentName;
  final String componentProductName;
  final double quantity;
  final String componentUnit;
  final double wastePercent;

  factory BomLine.fromJson(Map<String, Object?> json) {
    return BomLine(
      id: json['id'] as int,
      componentVariant: _intFromJson(json['component_variant']),
      componentName: json['component_name']?.toString() ?? '',
      componentProductName: json['component_product_name']?.toString() ?? '',
      quantity: _quantityFromJson(json['quantity']),
      componentUnit: json['component_unit']?.toString() ?? 'piece',
      wastePercent: _decimalFromJson(json['waste_percent']),
    );
  }
}

class BillOfMaterials {
  const BillOfMaterials({
    required this.id,
    required this.name,
    required this.variant,
    required this.variantName,
    required this.productName,
    required this.outputQuantity,
    required this.isActive,
    required this.lines,
    this.isPrepared = true,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String name;
  final int variant;
  final String variantName;
  final String productName;
  final int outputQuantity;
  final bool isActive;

  /// Whether the output product is made-to-order (consumed from the recipe when
  /// sold) rather than produced into stock ahead of time.
  final bool isPrepared;
  final List<BomLine> lines;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory BillOfMaterials.fromJson(Map<String, Object?> json) {
    final linesJson = (json['lines'] as List<Object?>?) ?? const [];
    return BillOfMaterials(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      variant: _intFromJson(json['variant']),
      variantName: json['variant_name']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      outputQuantity: _intFromJson(json['output_quantity']),
      isActive: json['is_active'] == true,
      isPrepared: json['is_prepared'] == true,
      lines: linesJson
          .whereType<Map<String, Object?>>()
          .map(BomLine.fromJson)
          .toList(growable: false),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class BillOfMaterialsPage {
  const BillOfMaterialsPage({required this.boms, required this.hasMore});

  final List<BillOfMaterials> boms;
  final bool hasMore;

  factory BillOfMaterialsPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(BillOfMaterials.fromJson)
        .toList(growable: false);

    return BillOfMaterialsPage(boms: results, hasMore: json['next'] != null);
  }
}

class BomLineDraft {
  const BomLineDraft({
    required this.componentVariant,
    required this.quantity,
    this.id,
    this.wastePercent = 0,
  });

  final int? id;
  final int componentVariant;
  final double quantity;
  final double wastePercent;

  Map<String, Object?> toJson() {
    return {
      if (id != null) 'id': id,
      'component_variant': componentVariant,
      'quantity': quantity.toStringAsFixed(3),
      'waste_percent': wastePercent.toStringAsFixed(2),
    };
  }
}

class BillOfMaterialsDraft {
  const BillOfMaterialsDraft({
    required this.name,
    required this.variant,
    required this.lines,
    this.id,
    this.outputQuantity = 1,
    this.isActive = true,
    this.makeToOrder = true,
  });

  final int? id;
  final String name;
  final int variant;
  final int outputQuantity;
  final bool isActive;

  /// When true (the default) the output product is marked made-to-order so the
  /// POS sells it by consuming the recipe instead of its own stock.
  final bool makeToOrder;
  final List<BomLineDraft> lines;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'variant': variant,
      'output_quantity': outputQuantity,
      'is_active': isActive,
      'make_to_order': makeToOrder,
      'lines': lines.map((line) => line.toJson()).toList(growable: false),
    };
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

double _decimalFromJson(Object? value) {
  return double.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

double _quantityFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}
