import 'product_variant.dart';

class CartLine {
  const CartLine({
    required this.variant,
    required this.quantity,
    this.notes = '',
    this.lineKey = '',
  });

  /// Builds a cart line with a stable, unique local [lineKey] so two lines of
  /// the same product (for example one carrying a kitchen note like
  /// "no onions" and one without) stay distinct for per-line edits. New lines
  /// must be created through this factory; [copyWith] preserves the key.
  factory CartLine.create({
    required ProductVariant variant,
    required double quantity,
    String notes = '',
  }) {
    _sequence += 1;
    return CartLine(
      variant: variant,
      quantity: quantity,
      notes: notes,
      lineKey: 'cart-$_sequence',
    );
  }

  static int _sequence = 0;

  final ProductVariant variant;
  final double quantity;

  /// Free-text kitchen instruction for this line (e.g. "no onions"). Empty for
  /// an ordinary line; a non-empty note also keeps the line from merging with
  /// fresh adds of the same variant.
  final String notes;

  /// Stable identity for this line within the cart, independent of the variant.
  final String lineKey;

  double get subtotal => variant.unitPrice * quantity;

  double get total => subtotal;

  CartLine copyWith({double? quantity, String? notes, String? lineKey}) {
    return CartLine(
      variant: variant,
      quantity: quantity ?? this.quantity,
      notes: notes ?? this.notes,
      lineKey: lineKey ?? this.lineKey,
    );
  }
}
