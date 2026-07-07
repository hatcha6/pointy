import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_bulk_action.dart';
import '../../../data/models/product_draft.dart';
import '../../../data/models/product_image_upload.dart';
import '../../../data/models/product_page.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/catalog_repository.dart';

enum CatalogBarcodeLookupStatus { found, notFound, error }

enum ProductCreateOutcome { failed, created, createdWithImageError }

class BulkActionResult {
  const BulkActionResult({required this.ok, required this.updated});

  final bool ok;
  final int updated;
}

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
  CatalogViewModel(this._catalogRepository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    loadProducts();
  }

  final CatalogRepository _catalogRepository;
  final AnalyticsEngine? _analyticsEngine;

  CatalogRepository get catalogRepository => _catalogRepository;

  List<Product> _products = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSaving = false;
  bool _hasMoreProducts = true;
  int _nextProductPage = 1;
  String? _errorMessage;
  // Browse "most bought" first by default (A–Z stays available in the filters).
  ProductQuery _query = const ProductQuery(ordering: ProductOrdering.mostBought);

  final Set<int> _selectedIds = {};
  bool _selectionMode = false;
  bool _isBulkRunning = false;

  List<Product> get products => List.unmodifiable(_products);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSaving => _isSaving;
  bool get hasMoreProducts => _hasMoreProducts;
  String? get errorMessage => _errorMessage;
  ProductQuery get query => _query;

  // ---- Multi-select / bulk operations ----
  bool get selectionMode => _selectionMode;
  bool get isBulkRunning => _isBulkRunning;
  Set<int> get selectedIds => Set.unmodifiable(_selectedIds);
  int get selectedCount => _selectedIds.length;
  bool isSelected(int id) => _selectedIds.contains(id);
  bool get allVisibleSelected =>
      _products.isNotEmpty && _products.every((p) => _selectedIds.contains(p.id));

  void enterSelectionMode() {
    if (!_selectionMode) {
      _selectionMode = true;
      notifyListeners();
    }
  }

  void exitSelectionMode() {
    if (_selectionMode || _selectedIds.isNotEmpty) {
      _selectionMode = false;
      _selectedIds.clear();
      notifyListeners();
    }
  }

  void toggleSelection(int id) {
    if (!_selectedIds.remove(id)) {
      _selectedIds.add(id);
    }
    _selectionMode = true;
    notifyListeners();
  }

  void selectAllVisible() {
    _selectedIds.addAll(_products.map((p) => p.id));
    _selectionMode = true;
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedIds.isNotEmpty) {
      _selectedIds.clear();
      notifyListeners();
    }
  }

  Future<BulkActionResult> bulkArchive({required bool archived}) {
    return _runBulk(
      (ids) =>
          _catalogRepository.bulkArchiveProducts(ids: ids, archived: archived),
    );
  }

  Future<BulkActionResult> bulkReprice({
    required ProductBulkRepriceMode mode,
    required double value,
  }) {
    return _runBulk(
      (ids) => _catalogRepository.bulkRepriceProducts(
        ids: ids,
        mode: mode,
        value: value,
      ),
    );
  }

  Future<BulkActionResult> bulkCategorize({
    required List<int> categoryIds,
    required ProductBulkCategorizeMode mode,
  }) {
    return _runBulk(
      (ids) => _catalogRepository.bulkCategorizeProducts(
        ids: ids,
        categoryIds: categoryIds,
        mode: mode,
      ),
    );
  }

  Future<BulkActionResult> bulkSetFlags({
    bool? isActive,
    bool? tracksExpiry,
    bool? isService,
    bool? isPrepared,
  }) {
    return _runBulk(
      (ids) => _catalogRepository.bulkSetProductFlags(
        ids: ids,
        isActive: isActive,
        tracksExpiry: tracksExpiry,
        isService: isService,
        isPrepared: isPrepared,
      ),
    );
  }

  Future<BulkActionResult> _runBulk(
    Future<Result<int>> Function(List<int> ids) action,
  ) async {
    if (_selectedIds.isEmpty || _isBulkRunning) {
      return const BulkActionResult(ok: false, updated: 0);
    }
    _isBulkRunning = true;
    notifyListeners();

    final result = await action(_selectedIds.toList());
    final BulkActionResult outcome;
    switch (result) {
      case Ok<int>(:final value):
        outcome = BulkActionResult(ok: true, updated: value);
        _isBulkRunning = false;
        // Refetch from the server (clears selection) so prices/flags/archive
        // state and ordering reflect the change.
        await loadProducts();
        return outcome;
      case Error<int>():
        outcome = const BulkActionResult(ok: false, updated: 0);
    }

    _isBulkRunning = false;
    notifyListeners();
    return outcome;
  }

  Future<void> loadProducts() async {
    _isLoading = true;
    _errorMessage = null;
    _nextProductPage = 1;
    _hasMoreProducts = true;
    _selectedIds.clear();
    _selectionMode = false;
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

  bool get isViewingArchived =>
      _query.archived == ProductArchivedFilter.onlyArchived;

  Future<void> setViewingArchived(bool value) async {
    final target = value
        ? ProductArchivedFilter.onlyArchived
        : ProductArchivedFilter.excludeArchived;
    if (_query.archived == target) {
      return;
    }
    _query = _query.copyWith(archived: target);
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

  Future<ProductCreateOutcome> createProduct(
    ProductDraft draft, {
    ProductImageUpload? imageUpload,
    String? imageImportToken,
  }) async {
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.createProduct(draft);
    switch (result) {
      case Ok<Product>():
        final imageAttached = await _attachProductImage(
          result.value.id,
          imageUpload: imageUpload,
          imageImportToken: imageImportToken,
        );
        _trackProductCreated(
          result.value,
          draft: draft,
          imageRequested: imageUpload != null || imageImportToken != null,
          imageAttached: imageAttached,
        );
        await loadProducts();
        _isSaving = false;
        if (!imageAttached) {
          _errorMessage = 'catalog_image_attach_error';
        }
        notifyListeners();
        return imageAttached
            ? ProductCreateOutcome.created
            : ProductCreateOutcome.createdWithImageError;
      case Error<Product>():
        _errorMessage = 'catalog_create_error';
        _isSaving = false;
        notifyListeners();
        return ProductCreateOutcome.failed;
    }
  }

  Future<bool> _attachProductImage(
    int productId, {
    ProductImageUpload? imageUpload,
    String? imageImportToken,
  }) async {
    if (imageUpload == null && (imageImportToken ?? '').isEmpty) {
      return true;
    }

    if (imageUpload != null) {
      final result = await _catalogRepository.uploadProductImage(
        productId: productId,
        upload: imageUpload,
      );
      return switch (result) {
        Ok() => true,
        Error() => false,
      };
    }

    final result = await _catalogRepository.importProductImage(
      productId: productId,
      importToken: imageImportToken!,
    );
    return switch (result) {
      Ok() => true,
      Error() => false,
    };
  }

  void _trackProductCreated(
    Product product, {
    required ProductDraft draft,
    required bool imageRequested,
    required bool imageAttached,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'catalog.product.created',
      entityType: 'product',
      entityId: product.id,
      attributes: {
        'product_id': product.id,
        'product_name': product.name,
        'is_active': product.isActive,
        'tracks_expiry': product.tracksExpiry,
        'image_requested': imageRequested,
        'image_attached': imageAttached,
        'source': 'catalog_product_form',
      },
      metrics: {
        'category_count': draft.categoryIds.length,
        'variant_option_count': draft.variantOptionIds.length,
        'variant_count': draft.variants.isEmpty ? 1 : draft.variants.length,
        'default_unit_price': draft.variantUnitPrice,
      },
    );
  }
}
