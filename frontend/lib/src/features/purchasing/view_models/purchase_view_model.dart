import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_page.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/purchase_repository.dart';

class PurchaseViewModel extends ChangeNotifier {
  PurchaseViewModel(this._catalogRepository, this._purchaseRepository) {
    loadCatalog();
  }

  final CatalogRepository _catalogRepository;
  final PurchaseRepository _purchaseRepository;

  List<Product> _products = [];
  final List<PurchaseDraftLine> _draft = [];
  final Map<int, double> _lastCostByProductId = {};
  SupplierContact? _selectedSupplier;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSubmitting = false;
  bool _isCreatingProduct = false;
  bool _receiveImmediately = true;
  bool _hasMoreProducts = true;
  int _nextProductPage = 1;
  String _supplierInvoiceNumber = '';
  String _supplierInvoiceDateInput = '';
  String? _errorMessage;
  ProductQuery _query = const ProductQuery(
    availability: ProductAvailabilityFilter.active,
  );

  List<Product> get products => List.unmodifiable(_products);
  List<PurchaseDraftLine> get draft => List.unmodifiable(_draft);
  SupplierContact? get selectedSupplier => _selectedSupplier;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSubmitting => _isSubmitting;
  bool get isCreatingProduct => _isCreatingProduct;
  bool get receiveImmediately => _receiveImmediately;
  bool get hasMoreProducts => _hasMoreProducts;
  String get supplierInvoiceNumber => _supplierInvoiceNumber;
  String get supplierInvoiceDateInput => _supplierInvoiceDateInput;
  DateTime? get supplierInvoiceDate =>
      _parseSupplierInvoiceDate(_supplierInvoiceDateInput);
  bool get hasInvalidSupplierInvoiceDate =>
      _supplierInvoiceDateInput.trim().isNotEmpty &&
      supplierInvoiceDate == null;
  String? get errorMessage => _errorMessage;
  ProductQuery get query => _query;

  double get subtotal => _draft.fold(0, (sum, line) => sum + line.subtotal);
  double get total => subtotal;
  bool get canSubmitDraft =>
      _draft.isNotEmpty &&
      _selectedSupplier != null &&
      !hasInvalidSupplierInvoiceDate &&
      !_isSubmitting;

  Future<void> loadCatalog() async {
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
        _products = _catalogRepository.sampleProducts(_query);
        _hasMoreProducts = false;
        _errorMessage = 'sample_catalog_notice';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMoreCatalog() async {
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
        _errorMessage = 'sample_catalog_notice';
    }

    _isLoadingMore = false;
    notifyListeners();
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

  Future<Product?> findProductByBarcode(String barcode) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return null;
    }

    final result = await _catalogRepository.findProductByBarcode(
      normalizedBarcode,
      activeOnly: true,
    );
    return switch (result) {
      Ok<Product?>(:final value) => value,
      Error<Product?>() => throw Exception('barcode lookup failed'),
    };
  }

  Future<Product?> createQuickProduct(ProductDraft draft) async {
    if (_isCreatingProduct || _isSubmitting) {
      return null;
    }

    _isCreatingProduct = true;
    notifyListeners();

    final result = await _catalogRepository.createProduct(draft);
    switch (result) {
      case Ok<Product>():
        await loadCatalog();
        _isCreatingProduct = false;
        notifyListeners();
        return result.value;
      case Error<Product>():
        _isCreatingProduct = false;
        notifyListeners();
        return null;
    }
  }

  Future<void> addProduct(
    Product product, {
    int quantity = 1,
    double? unitCost,
  }) async {
    if (_isSubmitting) {
      return;
    }

    final index = _draft.indexWhere((line) => line.product.id == product.id);
    if (index == -1) {
      final cost = unitCost ?? await _lastCostForProduct(product.id);
      if (_isSubmitting) {
        return;
      }
      _draft.add(
        PurchaseDraftLine(
          product: product,
          quantity: quantity.clamp(1, 999),
          unitCost: cost,
        ),
      );
    } else {
      final line = _draft[index];
      _draft[index] = line.copyWith(
        quantity: (line.quantity + quantity).clamp(1, 999),
        unitCost: unitCost,
      );
    }
    notifyListeners();
  }

  void decrementProduct(Product product) {
    if (_isSubmitting) {
      return;
    }

    final index = _draft.indexWhere((line) => line.product.id == product.id);
    if (index == -1) {
      return;
    }

    final line = _draft[index];
    if (line.quantity <= 1) {
      _draft.removeAt(index);
    } else {
      _draft[index] = line.copyWith(quantity: line.quantity - 1);
    }
    notifyListeners();
  }

  void updateLineCost(Product product, double unitCost) {
    if (_isSubmitting || unitCost < 0) {
      return;
    }
    final index = _draft.indexWhere((line) => line.product.id == product.id);
    if (index == -1) {
      return;
    }
    _lastCostByProductId[product.id] = unitCost;
    _draft[index] = _draft[index].copyWith(unitCost: unitCost);
    notifyListeners();
  }

  void clearDraft() {
    if (_isSubmitting) {
      return;
    }
    _draft.clear();
    _selectedSupplier = null;
    _supplierInvoiceNumber = '';
    _supplierInvoiceDateInput = '';
    notifyListeners();
  }

  void selectSupplier(SupplierContact? supplier) {
    if (_isSubmitting) {
      return;
    }
    _selectedSupplier = supplier;
    notifyListeners();
  }

  void updateReceiveImmediately(bool value) {
    if (_isSubmitting) {
      return;
    }
    _receiveImmediately = value;
    notifyListeners();
  }

  void updateSupplierInvoiceNumber(String value) {
    if (_isSubmitting) {
      return;
    }
    _supplierInvoiceNumber = value;
    notifyListeners();
  }

  void updateSupplierInvoiceDateInput(String value) {
    if (_isSubmitting) {
      return;
    }
    _supplierInvoiceDateInput = value;
    notifyListeners();
  }

  Future<Result<PurchaseSubmission>> submitDraft() async {
    final supplier = _selectedSupplier;
    if (_draft.isEmpty || supplier == null || _isSubmitting) {
      return Error(Exception('purchase draft is not ready'));
    }

    _isSubmitting = true;
    notifyListeners();

    final result = await _purchaseRepository.submitDraft(
      List.of(_draft),
      receiveImmediately: _receiveImmediately,
      supplierId: supplier.id,
      supplierInvoiceNumber: _supplierInvoiceNumber,
      supplierInvoiceDate: supplierInvoiceDate,
    );
    switch (result) {
      case Ok<PurchaseSubmission>():
        _draft.clear();
        _selectedSupplier = null;
        _supplierInvoiceNumber = '';
        _supplierInvoiceDateInput = '';
      case Error<PurchaseSubmission>():
        break;
    }

    _isSubmitting = false;
    notifyListeners();
    return result;
  }

  void rememberProductCost(Product product, double unitCost) {
    if (unitCost < 0) {
      return;
    }
    _lastCostByProductId[product.id] = unitCost;
  }

  Future<double> _lastCostForProduct(int productId) async {
    final cached = _lastCostByProductId[productId];
    if (cached != null) {
      return cached;
    }

    final result = await _purchaseRepository.loadLastProductCost(productId);
    final cost = switch (result) {
      Ok<double?>(:final value) => value ?? 0,
      Error<double?>() => 0.0,
    };
    _lastCostByProductId[productId] = cost;
    return cost;
  }

  DateTime? _parseSupplierInvoiceDate(String input) {
    final normalized = input.trim().replaceAll('/', '-');
    if (normalized.isEmpty) {
      return null;
    }
    return DateTime.tryParse(normalized);
  }
}
