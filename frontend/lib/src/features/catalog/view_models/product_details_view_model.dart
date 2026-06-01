import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/attachment_summary.dart';
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
    bool shouldLoadSaleHistory = true,
    bool shouldLoadPurchaseHistory = true,
  }) : _product = product,
       _shouldLoadSaleHistory = shouldLoadSaleHistory,
       _shouldLoadPurchaseHistory = shouldLoadPurchaseHistory {
    loadProduct();
    if (_shouldLoadSaleHistory) {
      loadSaleHistory();
    }
    if (_shouldLoadPurchaseHistory) {
      loadPurchaseHistory();
    }
  }

  final CatalogRepository _catalogRepository;
  final PurchaseRepository _purchaseRepository;
  final SaleRepository _saleRepository;
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
