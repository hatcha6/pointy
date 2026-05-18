part of 'pos_view_model.dart';

extension PosCatalogActions on PosViewModel {
  Future<void> loadCatalog() async {
    _isLoading = true;
    _errorMessage = null;
    _nextProductPage = 1;
    _hasMoreProducts = true;
    _notifyChanged();

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
        _products = _catalogRepository.sampleProducts(_query);
        _hasMoreProducts = false;
        _errorMessage = 'sample_catalog_notice';
    }

    _isLoading = false;
    _notifyChanged();
  }

  Future<void> loadMoreCatalog() async {
    if (_isLoading || _isLoadingMore || !_hasMoreProducts) {
      return;
    }

    _isLoadingMore = true;
    _notifyChanged();

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
        _errorMessage = 'sample_catalog_notice';
    }

    _isLoadingMore = false;
    _notifyChanged();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _query = _query.copyWith(search: search);
    await loadCatalog();
  }

  Future<void> applyQuery(ProductQuery query) async {
    if (query == _query) {
      return;
    }
    _query = query.copyWith(availability: ProductAvailabilityFilter.active);
    await loadCatalog();
  }
}
