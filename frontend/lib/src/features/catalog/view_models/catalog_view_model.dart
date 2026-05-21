import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_draft.dart';
import '../../../data/models/product_page.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/catalog_repository.dart';

enum CatalogBarcodeLookupStatus { found, notFound, error }

class CatalogBarcodeLookupOutcome {
  const CatalogBarcodeLookupOutcome._({required this.status, this.variant});

  const CatalogBarcodeLookupOutcome.found(ProductVariant variant)
    : this._(status: CatalogBarcodeLookupStatus.found, variant: variant);

  const CatalogBarcodeLookupOutcome.notFound()
    : this._(status: CatalogBarcodeLookupStatus.notFound);

  const CatalogBarcodeLookupOutcome.error()
    : this._(status: CatalogBarcodeLookupStatus.error);

  final CatalogBarcodeLookupStatus status;
  final ProductVariant? variant;

  Product? get product {
    final value = variant;
    return value == null ? null : Product.fromVariant(value);
  }
}

class CatalogViewModel extends ChangeNotifier {
  CatalogViewModel(this._catalogRepository) {
    loadProducts();
  }

  final CatalogRepository _catalogRepository;

  CatalogRepository get catalogRepository => _catalogRepository;

  List<Product> _products = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSaving = false;
  bool _hasMoreProducts = true;
  int _nextProductPage = 1;
  String? _errorMessage;
  ProductQuery _query = const ProductQuery();

  List<Product> get products => List.unmodifiable(_products);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSaving => _isSaving;
  bool get hasMoreProducts => _hasMoreProducts;
  String? get errorMessage => _errorMessage;
  ProductQuery get query => _query;

  Future<void> loadProducts() async {
    _isLoading = true;
    _errorMessage = null;
    _nextProductPage = 1;
    _hasMoreProducts = true;
    notifyListeners();

    final result = await _catalogRepository.loadProducts(
      query: _query,
      page: _nextProductPage,
    );
    switch (result) {
      case Ok<ProductPage>():
        _products = result.value.products;
        _hasMoreProducts = result.value.hasMore;
        _nextProductPage = 2;
      case Error<ProductPage>():
        _products = [];
        _hasMoreProducts = false;
        _errorMessage = 'catalog_load_error';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMoreProducts() async {
    if (_isLoading || _isLoadingMore || !_hasMoreProducts) {
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    final result = await _catalogRepository.loadProducts(
      query: _query,
      page: _nextProductPage,
    );
    switch (result) {
      case Ok<ProductPage>():
        _products = [..._products, ...result.value.products];
        _hasMoreProducts = result.value.hasMore;
        _nextProductPage += 1;
      case Error<ProductPage>():
        _errorMessage = 'catalog_load_error';
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _query = _query.copyWith(search: search);
    await loadProducts();
  }

  Future<void> applyQuery(ProductQuery query) async {
    _query = query;
    await loadProducts();
  }

  Future<CatalogBarcodeLookupOutcome> findVariantByBarcode(
    String barcode,
  ) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return const CatalogBarcodeLookupOutcome.notFound();
    }

    final result = await _catalogRepository.findProductVariantByBarcode(
      normalizedBarcode,
      activeOnly: false,
    );
    switch (result) {
      case Ok<ProductVariant?>(:final value):
        return value == null
            ? const CatalogBarcodeLookupOutcome.notFound()
            : CatalogBarcodeLookupOutcome.found(value);
      case Error<ProductVariant?>():
        return const CatalogBarcodeLookupOutcome.error();
    }
  }

  Future<bool> createProduct(ProductDraft draft) async {
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.createProduct(draft);
    switch (result) {
      case Ok<Product>():
        await loadProducts();
        _isSaving = false;
        notifyListeners();
        return true;
      case Error<Product>():
        _errorMessage = 'catalog_create_error';
        _isSaving = false;
        notifyListeners();
        return false;
    }
  }
}
