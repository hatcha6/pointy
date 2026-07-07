part of 'pos_view_model.dart';

extension PosCatalogActions on PosViewModel {
  Future<void> loadCatalog() {
    return _loadCatalogForCurrentQuery(queryChanged: false);
  }

  Future<void> _loadCatalogForCurrentQuery({required bool queryChanged}) {
    final querySnapshot = _query;
    final inFlight = _catalogLoadFuture;
    if (inFlight != null && _catalogLoadFutureQuery == querySnapshot) {
      return inFlight;
    }

    final requestVersion = ++_catalogRequestVersion;
    _catalogLoadFutureQuery = querySnapshot;
    late final Future<void> future;
    future =
        _performCatalogLoad(
          querySnapshot: querySnapshot,
          requestVersion: requestVersion,
          queryChanged: queryChanged,
        ).whenComplete(() {
          if (identical(_catalogLoadFuture, future)) {
            _catalogLoadFuture = null;
            _catalogLoadFutureQuery = null;
          }
        });
    _catalogLoadFuture = future;
    return future;
  }

  Future<void> _performCatalogLoad({
    required ProductQuery querySnapshot,
    required int requestVersion,
    required bool queryChanged,
  }) async {
    var changed = queryChanged;
    if (!_isLoading) {
      _isLoading = true;
      changed = true;
    }
    if (_isLoadingMore) {
      _isLoadingMore = false;
      changed = true;
    }
    if (_errorMessage != null) {
      _errorMessage = null;
      changed = true;
    }
    if (_nextProductPage != 1) {
      _nextProductPage = 1;
      changed = true;
    }
    if (!_hasMoreProducts) {
      _hasMoreProducts = true;
      changed = true;
    }
    if (changed) {
      _notifyChanged();
    }

    final result = await _catalogRepository.loadProducts(
      query: querySnapshot,
      page: 1,
    );
    if (requestVersion != _catalogRequestVersion || querySnapshot != _query) {
      return;
    }

    switch (result) {
      case Ok<ProductPage>():
        _products = result.value.products;
        _hasMoreProducts = result.value.hasMore;
        _nextProductPage = 2;
      case Error<ProductPage>():
        _products = _catalogRepository.sampleProducts(querySnapshot);
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

    final requestVersion = _catalogRequestVersion;
    final querySnapshot = _query;
    final page = _nextProductPage;
    final result = await _catalogRepository.loadProducts(
      query: querySnapshot,
      page: page,
    );
    final isCurrentPage =
        requestVersion == _catalogRequestVersion &&
        querySnapshot == _query &&
        page == _nextProductPage;
    if (!isCurrentPage) {
      if (_isLoadingMore) {
        _isLoadingMore = false;
        _notifyChanged();
      }
      return;
    }

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
    final normalizedSearch = search.trim();
    if (normalizedSearch == _query.search) {
      return;
    }
    _query = _query.copyWith(search: normalizedSearch);
    await _loadCatalogForCurrentQuery(queryChanged: true);
  }

  Future<void> applyQuery(ProductQuery query) async {
    final activeQuery = query.copyWith(
      search: query.search.trim(),
      availability: ProductAvailabilityFilter.active,
      stock: _catalogStockFilter,
    );
    if (activeQuery == _query) {
      return;
    }
    _query = activeQuery;
    await _loadCatalogForCurrentQuery(queryChanged: true);
  }

  /// Aligns the catalog's in-stock filter with the overselling setting and
  /// reloads if it changed. Called once the checkout settings load (or change).
  Future<void> syncCatalogStockVisibility() async {
    final desired = _catalogStockFilter;
    if (_query.stock == desired) {
      return;
    }
    _query = _query.copyWith(stock: desired);
    await _loadCatalogForCurrentQuery(queryChanged: true);
  }

  Future<PosProductSelectionResult> selectProductForSale(
    Product product,
  ) async {
    if (_isCheckingOut) {
      return const PosProductSelectionResult.unavailable();
    }

    final variantsResult = await _activeVariantsForProduct(product);
    switch (variantsResult) {
      case Ok<List<ProductVariant>>():
        final variants = variantsResult.value;
        if (variants.isEmpty) {
          return const PosProductSelectionResult.unavailable();
        }
        if (variants.length == 1) {
          final variant = variants.single;
          final defaultUnit = defaultSaleUnitOption(product, variant.unitPrice);
          if (defaultUnit.allowsFractional) {
            // Weighed/measured items still need a quantity before pricing.
            return PosProductSelectionResult.weighVariant(variant);
          }
          if (product.modifierGroups.isNotEmpty) {
            // Let the cashier pick modifiers before the line is added.
            return PosProductSelectionResult.chooseModifiers(variant);
          }
          // Whole units (piece, box, carton…) add directly at the product's
          // default unit — no dialog. The cashier switches units from the cart
          // line's unit chip instead.
          addVariant(
            variant,
            unit: defaultUnit.isBase ? null : defaultUnit,
            source: 'product_tile',
          );
          return const PosProductSelectionResult.added();
        }
        return PosProductSelectionResult.chooseVariant(variants);
      case Error<List<ProductVariant>>():
        return const PosProductSelectionResult.error();
    }
  }

  Future<Result<List<ProductVariant>>> _activeVariantsForProduct(
    Product product,
  ) async {
    final localVariants = product.activeVariants;
    if (localVariants.isNotEmpty) {
      return Ok(_withProductContext(localVariants, product));
    }

    final result = await _catalogRepository.loadVariantsForProduct(product.id);
    switch (result) {
      case Ok<ProductVariantPage>():
        return Ok(
          result.value.variants
              .where((variant) => variant.isSellable)
              .toList(growable: false),
        );
      case Error<ProductVariantPage>(:final exception):
        return Error(exception);
    }
  }

  /// Variants that come from the catalog list no longer embed their own
  /// `product_detail` — the parent product already carries it, and dropping that
  /// per-variant duplication roughly halved the catalog payload (and the tills'
  /// JSON-parse cost). Re-attach the product here so a cart line built from one of
  /// these variants can still resolve its units and modifiers via
  /// [Product.fromVariant]. Only fills a missing detail; variants fetched
  /// standalone (barcode scan, per-product endpoint) already carry theirs.
  List<ProductVariant> _withProductContext(
    List<ProductVariant> variants,
    Product product,
  ) {
    return [
      for (final variant in variants)
        variant.productDetail == null
            ? variant.copyWith(productDetail: product)
            : variant,
    ];
  }
}
