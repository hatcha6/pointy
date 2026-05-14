import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/catalog_repository.dart';

class PosViewModel extends ChangeNotifier {
  PosViewModel(this._catalogRepository) {
    loadCatalog();
  }

  final CatalogRepository _catalogRepository;

  List<Product> _products = [];
  final List<CartLine> _cart = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<Product> get products => List.unmodifiable(_products);
  List<CartLine> get cart => List.unmodifiable(_cart);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  double get subtotal => _cart.fold(0, (sum, line) => sum + line.subtotal);
  double get taxTotal => _cart.fold(0, (sum, line) => sum + line.tax);
  double get total => subtotal + taxTotal;

  Future<void> loadCatalog() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.loadProducts();
    switch (result) {
      case Ok<List<Product>>():
        _products = result.value;
      case Error<List<Product>>():
        _products = _catalogRepository.sampleProducts();
        _errorMessage = 'يتم عرض منتجات تجريبية إلى أن يعمل الخادم.';
    }

    _isLoading = false;
    notifyListeners();
  }

  void addProduct(Product product) {
    final index = _cart.indexWhere((line) => line.product.id == product.id);
    if (index == -1) {
      _cart.add(CartLine(product: product, quantity: 1));
    } else {
      final line = _cart[index];
      _cart[index] = line.copyWith(quantity: line.quantity + 1);
    }
    notifyListeners();
  }

  void decrementProduct(Product product) {
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
    notifyListeners();
  }

  void clearCart() {
    _cart.clear();
    notifyListeners();
  }
}
