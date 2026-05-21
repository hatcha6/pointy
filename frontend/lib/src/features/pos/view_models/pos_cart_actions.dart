part of 'pos_view_model.dart';

extension PosCartActions on PosViewModel {
  void addProduct(Product product, {int quantity = 1}) {
    if (_addProductToCart(product, quantity: quantity)) {
      _notifyChanged();
      unawaited(refreshDiscountPreview());
    }
  }

  void decrementProduct(Product product) {
    if (_isCheckingOut) {
      return;
    }

    final index = _cart.indexWhere(
      (line) => line.product.sellableId == product.sellableId,
    );
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
    unawaited(refreshDiscountPreview());
  }

  void clearCart() {
    if (_isCheckingOut || _cart.isEmpty) {
      return;
    }
    _cart.clear();
    _couponCode = '';
    _discountPreview = null;
    _hasDiscountPreviewError = false;
    _notifyChanged();
  }

  bool _addProductToCart(Product product, {int quantity = 1}) {
    if (_isCheckingOut || quantity <= 0) {
      return false;
    }

    final index = _cart.indexWhere(
      (line) => line.product.sellableId == product.sellableId,
    );
    if (index == -1) {
      _cart.add(CartLine(product: product, quantity: quantity));
    } else {
      final line = _cart[index];
      _cart[index] = line.copyWith(quantity: line.quantity + quantity);
    }
    return true;
  }
}
