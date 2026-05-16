part of 'pos_view_model.dart';

extension PosCartActions on PosViewModel {
  void addProduct(Product product) {
    if (_isCheckingOut) {
      return;
    }

    final index = _cart.indexWhere((line) => line.product.id == product.id);
    if (index == -1) {
      _cart.add(CartLine(product: product, quantity: 1));
    } else {
      final line = _cart[index];
      _cart[index] = line.copyWith(quantity: line.quantity + 1);
    }
    _notifyChanged();
  }

  void decrementProduct(Product product) {
    if (_isCheckingOut) {
      return;
    }

    final index = _cart.indexWhere((line) => line.product.id == product.id);
    if (index == -1) {
      return;
    }

    final line = _cart[index];
    if (line.quantity <= 1) {
      _cart.removeAt(index);
    } else {
      _cart[index] = line.copyWith(quantity: line.quantity - 1);
    }
    _notifyChanged();
  }

  void clearCart() {
    if (_isCheckingOut) {
      return;
    }
    _cart.clear();
    _notifyChanged();
  }
}
