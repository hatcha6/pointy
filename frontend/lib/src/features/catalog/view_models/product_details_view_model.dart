import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_update_draft.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/repositories/catalog_repository.dart';

class ProductDetailsViewModel extends ChangeNotifier {
  ProductDetailsViewModel(this._catalogRepository, Product product)
    : _product = product {
    loadProduct();
  }

  final CatalogRepository _catalogRepository;
  Product _product;
  bool _isLoading = false;
  bool _isSavingProduct = false;
  bool _isSavingVariant = false;
  String? _errorMessage;

  CatalogRepository get catalogRepository => _catalogRepository;
  Product get product => _product;
  List<ProductVariant> get variants {
    final variants =
        _product.variants.isEmpty && _product.defaultVariant != null
        ? [_product.defaultVariant!]
        : [..._product.variants];
    variants.sort((a, b) {
      if (a.isDefault != b.isDefault) {
        return a.isDefault ? -1 : 1;
      }
      return a.displayLabel.compareTo(b.displayLabel);
    });
    return variants;
  }

  bool get isLoading => _isLoading;
  bool get isSavingProduct => _isSavingProduct;
  bool get isSavingVariant => _isSavingVariant;
  String? get errorMessage => _errorMessage;

  Future<void> loadProduct() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.loadProduct(_product.id);
    switch (result) {
      case Ok<Product>():
        _product = result.value;
      case Error<Product>():
        _errorMessage = 'product_detail_load_error';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> updateProduct(ProductUpdateDraft draft) async {
    if (_isSavingProduct) {
      return false;
    }

    _isSavingProduct = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.updateProduct(
      id: _product.id,
      draft: draft,
    );
    switch (result) {
      case Ok<Product>():
        _product = result.value;
        _isSavingProduct = false;
        notifyListeners();
        return true;
      case Error<Product>():
        _errorMessage = 'product_update_error';
        _isSavingProduct = false;
        notifyListeners();
        return false;
    }
  }

  Future<bool> createVariant(ProductVariantDraft draft) async {
    if (_isSavingVariant) {
      return false;
    }

    _isSavingVariant = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.createVariantForProduct(
      _product.id,
      draft,
    );
    switch (result) {
      case Ok<ProductVariant>():
        await loadProduct();
        _isSavingVariant = false;
        notifyListeners();
        return true;
      case Error<ProductVariant>():
        _errorMessage = 'variant_create_error';
        _isSavingVariant = false;
        notifyListeners();
        return false;
    }
  }

  Future<bool> updateVariant({
    required int id,
    required ProductVariantDraft draft,
  }) async {
    if (_isSavingVariant) {
      return false;
    }

    _isSavingVariant = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.updateProductVariant(
      id: id,
      draft: draft,
    );
    switch (result) {
      case Ok<ProductVariant>():
        await loadProduct();
        _isSavingVariant = false;
        notifyListeners();
        return true;
      case Error<ProductVariant>():
        _errorMessage = 'variant_update_error';
        _isSavingVariant = false;
        notifyListeners();
        return false;
    }
  }
}
