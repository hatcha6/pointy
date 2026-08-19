import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/attachment_summary.dart';
import '../../../data/models/bought_together_product.dart';
import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_image_upload.dart';
import '../../../data/models/product_update_draft.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/sale_order_page.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/sale_repository.dart';

class ProductDetailsViewModel extends ChangeNotifier {
  ProductDetailsViewModel(
    this._catalogRepository,
    this._purchaseRepository,
    this._saleRepository,
    Product product, {
    AnalyticsEngine? analyticsEngine,
    bool shouldLoadSaleHistory = true,
    bool shouldLoadPurchaseHistory = true,
  }) : _analyticsEngine = analyticsEngine,
       _product = product,
       _shouldLoadSaleHistory = shouldLoadSaleHistory,
       _shouldLoadPurchaseHistory = shouldLoadPurchaseHistory {
    loadProduct();
    if (_shouldLoadSaleHistory) {
      loadSaleHistory();
    }
    if (_shouldLoadPurchaseHistory) {
      loadPurchaseHistory();
      loadCostSummary();
    }
    loadBoughtTogether();
  }

  final CatalogRepository _catalogRepository;
  final PurchaseRepository _purchaseRepository;
  final SaleRepository _saleRepository;
  final AnalyticsEngine? _analyticsEngine;
  final bool _shouldLoadSaleHistory;
  final bool _shouldLoadPurchaseHistory;
  Product _product;
  bool _isLoading = false;
  bool _isSavingProduct = false;
  bool _isSavingVariant = false;
  bool _isSavingImage = false;
  bool _isLoadingSaleHistory = false;
  bool _isLoadingMoreSaleHistory = false;
  bool _isLoadingPurchaseHistory = false;
  bool _isLoadingMorePurchaseHistory = false;
  bool _hasSaleHistoryError = false;
  bool _hasPurchaseHistoryError = false;
  bool _hasMoreSaleHistory = false;
  bool _hasMorePurchaseHistory = false;
  int _saleHistoryPage = 1;
  int _purchaseHistoryPage = 1;
  List<SaleOrder> _recentSaleOrders = [];
  List<PurchaseOrder> _recentPurchaseOrders = [];
  bool _isLoadingBoughtTogether = false;
  bool _hasBoughtTogetherError = false;
  List<BoughtTogetherProduct> _boughtTogether = [];
  bool _isLoadingCostSummary = false;
  bool _hasCostSummaryError = false;
  bool _isSavingPrices = false;
  List<VariantCostSummary> _costSummaries = [];
  String? _errorMessage;
  // Duplicate SKU/barcode findings from the last failed variant save, so the
  // variant dialog can mark the offending field.
  List<CatalogIdentityConflict> _variantSaveConflicts = const [];

  CatalogRepository get catalogRepository => _catalogRepository;
  SaleRepository get saleRepository => _saleRepository;
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
  bool get isLoadingSaleHistory => _isLoadingSaleHistory;
  bool get isLoadingMoreSaleHistory => _isLoadingMoreSaleHistory;
  bool get isLoadingPurchaseHistory => _isLoadingPurchaseHistory;
  bool get isLoadingMorePurchaseHistory => _isLoadingMorePurchaseHistory;
  bool get hasSaleHistoryError => _hasSaleHistoryError;
  bool get hasPurchaseHistoryError => _hasPurchaseHistoryError;
  bool get hasMoreSaleHistory => _hasMoreSaleHistory;
  bool get hasMorePurchaseHistory => _hasMorePurchaseHistory;
  List<SaleOrder> get recentSaleOrders => List.unmodifiable(_recentSaleOrders);
  List<PurchaseOrder> get recentPurchaseOrders =>
      List.unmodifiable(_recentPurchaseOrders);
  bool get isLoadingBoughtTogether => _isLoadingBoughtTogether;
  bool get hasBoughtTogetherError => _hasBoughtTogetherError;
  List<BoughtTogetherProduct> get boughtTogether =>
      List.unmodifiable(_boughtTogether);
  bool get isLoadingCostSummary => _isLoadingCostSummary;
  bool get hasCostSummaryError => _hasCostSummaryError;
  bool get isSavingPrices => _isSavingPrices;
  List<VariantCostSummary> get costSummaries =>
      List.unmodifiable(_costSummaries);
  String? get errorMessage => _errorMessage;
  List<CatalogIdentityConflict> get variantSaveConflicts =>
      List.unmodifiable(_variantSaveConflicts);

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

  Future<void> loadBoughtTogether() async {
    _isLoadingBoughtTogether = true;
    _hasBoughtTogetherError = false;
    notifyListeners();

    final result = await _catalogRepository.loadBoughtTogether(_product.id);
    switch (result) {
      case Ok<List<BoughtTogetherProduct>>():
        _boughtTogether = result.value;
      case Error<List<BoughtTogetherProduct>>():
        _boughtTogether = [];
        _hasBoughtTogetherError = true;
    }

    _isLoadingBoughtTogether = false;
    notifyListeners();
  }

  Future<void> loadCostSummary() async {
    if (!_shouldLoadPurchaseHistory) {
      return;
    }
    _isLoadingCostSummary = true;
    _hasCostSummaryError = false;
    notifyListeners();

    final result = await _purchaseRepository.loadProductCostSummary(
      _product.id,
    );
    switch (result) {
      case Ok<List<VariantCostSummary>>():
        _costSummaries = result.value;
      case Error<List<VariantCostSummary>>():
        _costSummaries = [];
        _hasCostSummaryError = true;
    }

    _isLoadingCostSummary = false;
    notifyListeners();
  }

  /// Writes explicit new selling prices for the product's variants from the
  /// "Change prices" dialog, then refreshes the product and its cost summary.
  Future<bool> setVariantPrices(Map<int, double> pricesByVariant) async {
    if (_isSavingPrices || pricesByVariant.isEmpty) {
      return false;
    }

    _isSavingPrices = true;
    _errorMessage = null;
    notifyListeners();

    final result = await _catalogRepository.setVariantPrices(
      productId: _product.id,
      pricesByVariant: pricesByVariant,
    );
    switch (result) {
      case Ok<Product>():
        _product = result.value;
        _isSavingPrices = false;
        notifyListeners();
        unawaited(loadCostSummary());
        return true;
      case Error<Product>():
        _errorMessage = 'variant_prices_update_error';
        _isSavingPrices = false;
        notifyListeners();
        return false;
    }
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
        _trackProductUpdated(result.value, draft);
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

  Future<bool> archiveProduct() => _setArchived(archived: true);

  Future<bool> restoreProduct() => _setArchived(archived: false);

  Future<bool> _setArchived({required bool archived}) async {
    if (_isSavingProduct) {
      return false;
    }

    _isSavingProduct = true;
    _errorMessage = null;
    notifyListeners();

    final result = archived
        ? await _catalogRepository.archiveProduct(_product.id)
        : await _catalogRepository.restoreProduct(_product.id);
    switch (result) {
      case Ok<Product>():
        _product = result.value;
        _trackArchiveChange(result.value, archived: archived);
        _isSavingProduct = false;
        notifyListeners();
        return true;
      case Error<Product>():
        _errorMessage = archived
            ? 'product_archive_error'
            : 'product_restore_error';
        _isSavingProduct = false;
        notifyListeners();
        return false;
    }
  }

  void _trackArchiveChange(Product product, {required bool archived}) {
    trackAuditEvent(
      _analyticsEngine,
      name: archived
          ? 'catalog.product.archived'
          : 'catalog.product.restored',
      entityType: 'product',
      entityId: product.id,
      attributes: {
        'product_id': product.id,
        'product_name': product.name,
        'is_active': product.isActive,
        'source': 'catalog_product_details',
      },
    );
  }

  Future<bool> createVariant(ProductVariantDraft draft) async {
    if (_isSavingVariant) {
      return false;
    }

    _isSavingVariant = true;
    _errorMessage = null;
    _variantSaveConflicts = const [];
    notifyListeners();

    final result = await _catalogRepository.createVariantForProduct(
      _product.id,
      draft,
    );
    switch (result) {
      case Ok<ProductVariant>():
        _trackVariantChanged(
          name: 'catalog.product_variant.created',
          variant: result.value,
          source: 'catalog_variant_form',
        );
        await loadProduct();
        _isSavingVariant = false;
        notifyListeners();
        return true;
      case Error<ProductVariant>():
        _variantSaveConflicts = catalogConflictsFromException(result.exception);
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
    _variantSaveConflicts = const [];
    notifyListeners();

    final result = await _catalogRepository.updateProduct(
      id: _product.id,
      draft: ProductUpdateDraft(
        name: _product.name,
        description: _product.description,
        isActive: _product.isActive,
        tracksExpiry: _product.tracksExpiry,
        unit: _product.unit,
        isService: _product.isService,
        isPrepared: _product.isPrepared,
        categoryIds: [for (final category in _product.categories) category.id],
        variantOptionIds: variantOptionIds,
        variants: variants,
      ),
    );
    switch (result) {
      case Ok<Product>():
        _product = result.value;
        _trackGeneratedVariants(
          product: result.value,
          variantOptionIds: variantOptionIds,
          requestedVariants: variants,
        );
        _isSavingVariant = false;
        notifyListeners();
        return true;
      case Error<Product>():
        _variantSaveConflicts = catalogConflictsFromException(result.exception);
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
    _variantSaveConflicts = const [];
    notifyListeners();

    final result = await _catalogRepository.updateProductVariant(
      id: id,
      draft: draft,
    );
    switch (result) {
      case Ok<ProductVariant>():
        _trackVariantChanged(
          name: 'catalog.product_variant.updated',
          variant: result.value,
          source: 'catalog_variant_form',
        );
        await loadProduct();
        _isSavingVariant = false;
        notifyListeners();
        return true;
      case Error<ProductVariant>():
        _variantSaveConflicts = catalogConflictsFromException(result.exception);
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
    return _handleProductImageSave(
      result,
      eventName: 'catalog.product.image_uploaded',
      source: 'catalog_product_details',
    );
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
    return _handleProductImageSave(
      result,
      eventName: 'catalog.product.image_imported',
      source: 'catalog_product_details',
    );
  }

  Future<bool> _handleProductImageSave(
    Result<AttachmentSummary> result, {
    required String eventName,
    required String source,
  }) async {
    switch (result) {
      case Ok<AttachmentSummary>():
        _trackProductImageSaved(eventName: eventName, source: source);
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

  void _trackProductUpdated(Product product, ProductUpdateDraft draft) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'catalog.product.updated',
      entityType: 'product',
      entityId: product.id,
      attributes: {
        'product_id': product.id,
        'product_name': product.name,
        'is_active': product.isActive,
        'tracks_expiry': product.tracksExpiry,
        'source': 'catalog_product_details',
      },
      metrics: {
        'category_count': draft.categoryIds.length,
        if (draft.variantOptionIds != null)
          'variant_option_count': draft.variantOptionIds!.length,
        'variant_count': product.variants.length,
        'active_variant_count': product.activeVariants.length,
      },
    );
  }

  void _trackVariantChanged({
    required String name,
    required ProductVariant variant,
    required String source,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'product_variant',
      entityId: variant.id,
      attributes: {
        'product_id': variant.productId,
        'product_name': _product.name,
        'variant_id': variant.id,
        'variant_name': variant.displayLabel,
        'sku': variant.sku,
        'barcode_present': variant.barcode.trim().isNotEmpty,
        'is_active': variant.isActive,
        'is_default': variant.isDefault,
        'source': source,
      },
      metrics: {
        'unit_price': variant.unitPrice,
        'option_value_count': variant.optionValueIds.length,
      },
    );
  }

  void _trackGeneratedVariants({
    required Product product,
    required List<int> variantOptionIds,
    required List<ProductVariantDraft> requestedVariants,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'catalog.product.variants_generated',
      entityType: 'product',
      entityId: product.id,
      attributes: {
        'product_id': product.id,
        'product_name': product.name,
        'source': 'catalog_variant_generator',
      },
      metrics: {
        'variant_option_count': variantOptionIds.length,
        'generated_variant_count': requestedVariants.length,
        'variant_count': product.variants.length,
      },
    );
  }

  void _trackProductImageSaved({
    required String eventName,
    required String source,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: eventName,
      entityType: 'product',
      entityId: _product.id,
      attributes: {
        'product_id': _product.id,
        'product_name': _product.name,
        'source': source,
      },
      metrics: {'image_count': _product.imageAttachments.length + 1},
    );
  }

  Future<void> loadSaleHistory() async {
    await _loadSaleHistory(reset: true);
  }

  Future<void> loadMoreSaleHistory() async {
    await _loadSaleHistory(reset: false);
  }

  Future<void> loadPurchaseHistory() async {
    await _loadPurchaseHistory(reset: true);
  }

  Future<void> loadMorePurchaseHistory() async {
    await _loadPurchaseHistory(reset: false);
  }

  Future<void> _loadSaleHistory({required bool reset}) async {
    if (!_shouldLoadSaleHistory) {
      return;
    }
    if (reset) {
      _saleHistoryPage = 1;
      _isLoadingSaleHistory = true;
    } else {
      if (_isLoadingMoreSaleHistory || !_hasMoreSaleHistory) {
        return;
      }
      _isLoadingMoreSaleHistory = true;
    }
    _hasSaleHistoryError = false;
    notifyListeners();

    final page = reset ? 1 : _saleHistoryPage + 1;
    final result = await _saleRepository.loadOrders(
      query: SaleOrderQuery(productId: _product.id),
      page: page,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _recentSaleOrders = reset
            ? result.value.orders
            : [..._recentSaleOrders, ...result.value.orders];
        _hasMoreSaleHistory = result.value.hasMore;
        _saleHistoryPage = page;
      case Error<SaleOrderPage>():
        if (reset) {
          _recentSaleOrders = [];
        }
        _hasSaleHistoryError = true;
    }

    _isLoadingSaleHistory = false;
    _isLoadingMoreSaleHistory = false;
    notifyListeners();
  }

  Future<void> _loadPurchaseHistory({required bool reset}) async {
    if (!_shouldLoadPurchaseHistory) {
      return;
    }
    if (reset) {
      _purchaseHistoryPage = 1;
      _isLoadingPurchaseHistory = true;
    } else {
      if (_isLoadingMorePurchaseHistory || !_hasMorePurchaseHistory) {
        return;
      }
      _isLoadingMorePurchaseHistory = true;
    }
    _hasPurchaseHistoryError = false;
    notifyListeners();

    final page = reset ? 1 : _purchaseHistoryPage + 1;
    final result = await _purchaseRepository.loadPurchaseOrders(
      query: PurchaseOrderQuery(productId: _product.id),
      page: page,
    );
    switch (result) {
      case Ok<PurchaseOrderPage>():
        _recentPurchaseOrders = reset
            ? result.value.orders
            : [..._recentPurchaseOrders, ...result.value.orders];
        _hasMorePurchaseHistory = result.value.hasMore;
        _purchaseHistoryPage = page;
      case Error<PurchaseOrderPage>():
        if (reset) {
          _recentPurchaseOrders = [];
        }
        _hasPurchaseHistoryError = true;
    }

    _isLoadingPurchaseHistory = false;
    _isLoadingMorePurchaseHistory = false;
    notifyListeners();
  }
}
