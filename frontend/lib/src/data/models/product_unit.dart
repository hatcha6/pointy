import 'unit_of_measure.dart';

/// An additional unit a product can be transacted in, with its per-product
/// conversion to the base (stock) unit and an optional custom price. Mirrors the
/// backend `catalog.ProductUnit`. The base unit is implicit and never appears
/// here.
class ProductUnit {
  const ProductUnit({
    required this.unit,
    required this.factorToBase,
    this.id,
    this.price,
    this.isSellable = true,
    this.isPurchasable = true,
    this.displayOrder = 0,
  });

  final int? id;
  final UnitOfMeasure unit;

  /// How many base units make up one of this unit (1 box = 12 pieces → 12).
  final double factorToBase;

  /// Custom price for one of this unit; null = derive from the variant price.
  final double? price;
  final bool isSellable;
  final bool isPurchasable;
  final int displayOrder;

  String get code => unit.code;
  String get label => unit.label;
  bool get allowsFractional => unit.allowsFractional;

  /// Price for one of this unit given the base/variant price.
  double resolvedPrice(double baseUnitPrice) =>
      price ?? baseUnitPrice * factorToBase;

  ProductUnit copyWith({
    UnitOfMeasure? unit,
    double? factorToBase,
    Object? price = _noChange,
    bool? isSellable,
    bool? isPurchasable,
    int? displayOrder,
  }) {
    return ProductUnit(
      id: id,
      unit: unit ?? this.unit,
      factorToBase: factorToBase ?? this.factorToBase,
      price: identical(price, _noChange) ? this.price : price as double?,
      isSellable: isSellable ?? this.isSellable,
      isPurchasable: isPurchasable ?? this.isPurchasable,
      displayOrder: displayOrder ?? this.displayOrder,
    );
  }

  factory ProductUnit.fromJson(Map<String, Object?> json) {
    final detail = json['unit_detail'];
    final unit = detail is Map<String, Object?>
        ? UnitOfMeasure.fromJson(detail)
        : UnitOfMeasure(
            id: 0,
            code: json['unit']?.toString() ?? '',
            name: json['unit']?.toString() ?? '',
          );
    return ProductUnit(
      id: json['id'] is num ? (json['id'] as num).toInt() : null,
      unit: unit,
      factorToBase: _doubleFromJson(json['factor_to_base'], fallback: 1),
      price: _doubleOrNull(json['price']),
      isSellable: (json['is_sellable'] as bool?) ?? true,
      isPurchasable: (json['is_purchasable'] as bool?) ?? true,
      displayOrder: json['display_order'] is num
          ? (json['display_order'] as num).toInt()
          : 0,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'unit': unit.code,
      'factor_to_base': factorToBase.toString(),
      'price': price?.toStringAsFixed(2),
      'is_sellable': isSellable,
      'is_purchasable': isPurchasable,
      'display_order': displayOrder,
    };
  }
}

const Object _noChange = Object();

double _doubleFromJson(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  return double.tryParse((value ?? '').toString()) ?? fallback;
}

double? _doubleOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}
