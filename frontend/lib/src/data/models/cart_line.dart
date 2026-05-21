import 'product_variant.dart';

class CartLine {
  const CartLine({required this.variant, required this.quantity});

  final ProductVariant variant;
  final int quantity;

  double get subtotal => variant.unitPrice * quantity;

  double get total => subtotal;

  CartLine copyWith({int? quantity}) {
    return CartLine(variant: variant, quantity: quantity ?? this.quantity);
  }
}
