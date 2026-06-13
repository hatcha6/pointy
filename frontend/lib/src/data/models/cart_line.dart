import 'modifier_group.dart';
import 'product_variant.dart';

class CartLine {
  const CartLine({
    required this.variant,
    required this.quantity,
    this.notes = '',
    this.modifiers = const [],
    this.lineKey = '',
  });

  /// Builds a cart line with a stable, unique local [lineKey] so two lines of
  /// the same product (different notes or modifiers) stay distinct for per-line
  /// edits. New lines must be created through this factory; [copyWith] preserves
  /// the key.
  factory CartLine.create({
    required ProductVariant variant,
    required double quantity,
    String notes = '',
    List<CartLineModifier> modifiers = const [],
  }) {
    _sequence += 1;
    return CartLine(
      variant: variant,
      quantity: quantity,
      notes: notes,
      modifiers: modifiers,
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

  /// Stable identity for this line within the cart, independent of the variant.
  final String lineKey;

  double get unitPrice =>
      variant.unitPrice +
      modifiers.fold<double>(0, (sum, modifier) => sum + modifier.unitDelta);

  double get subtotal => unitPrice * quantity;

  double get total => subtotal;

  /// Order-independent identity of the selected modifiers, used to decide
  /// whether a fresh add can merge into this line.
  String get modifierSignature {
    final parts = modifiers
        .map((modifier) => '${modifier.optionId}:${modifier.quantity}')
        .toList()
      ..sort();
    return parts.join(',');
  }

  CartLine copyWith({
    double? quantity,
    String? notes,
    List<CartLineModifier>? modifiers,
    String? lineKey,
  }) {
    return CartLine(
      variant: variant,
      quantity: quantity ?? this.quantity,
      notes: notes ?? this.notes,
      modifiers: modifiers ?? this.modifiers,
      lineKey: lineKey ?? this.lineKey,
    );
  }
}
