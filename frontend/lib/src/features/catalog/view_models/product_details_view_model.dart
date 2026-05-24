import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/attachment_summary.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_image_upload.dart';
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
  bool _isSavingImage = false;
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
  bool get isSavingImage => _isSavingImage;
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

  Future<bool> saveGeneratedVariants({
    required List<int> variantOptionIds,
    required List<ProductVariantDraft> variants,
  }) async {
    if (_isSavingVariant) {
      return false;
    }

    _isSavingVariant = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.updateProduct(
      id: _product.id,
      draft: ProductUpdateDraft(
        name: _product.name,
        description: _product.description,
        isActive: _product.isActive,
        categoryIds: [for (final category in _product.categories) category.id],
        variantOptionIds: variantOptionIds,
        variants: variants,
      ),
    );
    switch (result) {
      case Ok<Product>():
        _product = result.value;
        _isSavingVariant = false;
        notifyListeners();
        return true;
      case Error<Product>():
        _errorMessage = 'variant_generate_error';
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

  Future<bool> uploadProductImage(ProductImageUpload upload) async {
    if (_isSavingImage) {
      return false;
    }

    _isSavingImage = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.uploadProductImage(
      productId: _product.id,
      upload: upload,
    );
    return _handleProductImageSave(result);
  }

  Future<bool> importProductImage(String importToken) async {
    if (_isSavingImage) {
      return false;
    }

    _isSavingImage = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.importProductImage(
      productId: _product.id,
      importToken: importToken,
    );
    return _handleProductImageSave(result);
  }

  Future<bool> _handleProductImageSave(Result<AttachmentSummary> result) async {
    switch (result) {
      case Ok<AttachmentSummary>():
        await loadProduct();
        _isSavingImage = false;
        notifyListeners();
        return true;
      case Error<AttachmentSummary>():
        _errorMessage = 'product_image_attach_error';
        _isSavingImage = false;
        notifyListeners();
        return false;
    }
  }
}
