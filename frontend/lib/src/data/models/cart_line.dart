import 'modifier_group.dart';
import 'product_variant.dart';

class CartLine {
  const CartLine({
    required this.variant,
    required this.quantity,
    this.notes = '',
    this.modifiers = const [],
    this.unitCode = '',
    this.unitLabel = '',
    this.unitFactor = 1,
    this.unitPriceOverride,
    this.lineKey = '',
  });

  /// Builds a cart line with a stable, unique local [lineKey] so two lines of
  /// the same product (different notes, modifiers, or unit) stay distinct for
  /// per-line edits. New lines must be created through this factory; [copyWith]
  /// preserves the key.
  factory CartLine.create({
    required ProductVariant variant,
    required double quantity,
    String notes = '',
    List<CartLineModifier> modifiers = const [],
    String unitCode = '',
    String unitLabel = '',
    double unitFactor = 1,
    double? unitPriceOverride,
  }) {
    _sequence += 1;
    return CartLine(
      variant: variant,
      quantity: quantity,
      notes: notes,
      modifiers: modifiers,
      unitCode: unitCode,
      unitLabel: unitLabel,
      unitFactor: unitFactor,
      unitPriceOverride: unitPriceOverride,
      lineKey: 'cart-$_sequence',
    );
  }

  static int _sequence = 0;

  final ProductVariant variant;
  final double quantity;

  /// Free-text kitchen instruction for this line (e.g. "no onions").
  final String notes;

  /// Structured modifier choices for this line (e.g. "Oat milk", "Extra shot
  /// ×2"). Each adds its per-unit delta to the line price.
  final List<CartLineModifier> modifiers;

  /// The unit this line is sold in (a UnitOfMeasure.code). Empty = the product's
  /// base unit.
  final String unitCode;

  /// Display label for [unitCode], resolved when the unit was chosen.
  final String unitLabel;

  /// How many base units one of [unitCode] is worth (1 box = 12 → 12).
  final double unitFactor;

  /// Resolved per-unit price for [unitCode] (before modifiers); null = the bare
  /// variant price (base unit).
  final double? unitPriceOverride;

  /// Stable identity for this line within the cart, independent of the variant.
  final String lineKey;

  bool get isBaseUnit => unitCode.isEmpty || unitFactor == 1;

  /// Quantity converted to the product's base unit (for stock-style display).
  double get baseQuantity => quantity * unitFactor;

  double get unitPrice =>
      (unitPriceOverride ?? variant.unitPrice) +
      modifiers.fold<double>(0, (sum, modifier) => sum + modifier.unitDelta);

  double get subtotal => unitPrice * quantity;

  double get total => subtotal;

  /// Order-independent identity of the selected modifiers, used to decide
  /// whether a fresh add can merge into this line.
  String get modifierSignature {
    final parts =
        modifiers
            .map((modifier) => '${modifier.optionId}:${modifier.quantity}')
            .toList()
          ..sort();
    return parts.join(',');
  }

  CartLine copyWith({
    double? quantity,
    String? notes,
    List<CartLineModifier>? modifiers,
    String? unitCode,
    String? unitLabel,
    double? unitFactor,
    // Sentinel so the override can be cleared back to null (switching to base).
    Object? unitPriceOverride = _noChange,
    String? lineKey,
  }) {
    return CartLine(
      variant: variant,
      quantity: quantity ?? this.quantity,
      notes: notes ?? this.notes,
      modifiers: modifiers ?? this.modifiers,
      unitCode: unitCode ?? this.unitCode,
      unitLabel: unitLabel ?? this.unitLabel,
      unitFactor: unitFactor ?? this.unitFactor,
      unitPriceOverride: identical(unitPriceOverride, _noChange)
          ? this.unitPriceOverride
          : unitPriceOverride as double?,
      lineKey: lineKey ?? this.lineKey,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'variant': variant.toCartJson(),
      'quantity': quantity,
      'notes': notes,
      'modifiers': modifiers
          .map((modifier) => modifier.toJson())
          .toList(growable: false),
      'unit_code': unitCode,
      'unit_label': unitLabel,
      'unit_factor': unitFactor,
      'unit_price_override': unitPriceOverride,
      'line_key': lineKey,
    };
  }

  factory CartLine.fromJson(Map<String, Object?> json) {
    final variantJson = json['variant'];
    if (variantJson is! Map<String, Object?>) {
      throw const FormatException('cart line is missing its variant');
    }
    final lineKey = json['line_key']?.toString() ?? '';
    // Keep the local sequence ahead of any restored key so newly-added lines
    // never collide with a restored one.
    final suffix = int.tryParse(lineKey.split('-').last);
    if (suffix != null && suffix > _sequence) {
      _sequence = suffix;
    }
    final modifiersJson = json['modifiers'];
    final override = json['unit_price_override'];
    return CartLine(
      variant: ProductVariant.fromJson(variantJson),
      quantity: _doubleFromJson(json['quantity']),
      notes: json['notes']?.toString() ?? '',
      modifiers: modifiersJson is List<Object?>
          ? modifiersJson
                .whereType<Map<String, Object?>>()
                .map(CartLineModifier.fromJson)
                .toList(growable: false)
          : const [],
      unitCode: json['unit_code']?.toString() ?? '',
      unitLabel: json['unit_label']?.toString() ?? '',
      unitFactor: _doubleFromJson(json['unit_factor'], fallback: 1),
      unitPriceOverride: override == null ? null : _doubleFromJson(override),
      lineKey: lineKey,
    );
  }
}

const Object _noChange = Object();

double _doubleFromJson(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? '').toString()) ?? fallback;
}
