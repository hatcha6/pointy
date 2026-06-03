import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_draft.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/purchase_repository.dart';

class PurchaseViewModel extends ChangeNotifier {
  PurchaseViewModel(this._catalogRepository, this._purchaseRepository) {
    loadCatalog();
  }

  final CatalogRepository _catalogRepository;
  final PurchaseRepository _purchaseRepository;

  CatalogRepository get catalogRepository => _catalogRepository;

  List<ProductVariant> _variants = [];
  final List<PurchaseDraftLine> _draft = [];
  final Map<int, double> _lastCostByVariantId = {};
  SupplierContact? _selectedSupplier;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSubmitting = false;
  bool _isCreatingProduct = false;
  bool _receiveImmediately = true;
  bool _hasMoreProducts = true;
  int _nextVariantPage = 1;
  String _supplierInvoiceNumber = '';
  String _supplierInvoiceDateInput = '';
  List<PurchaseLandedCostEntry> _landedCostEntries = [];
  String _discountCode = '';
  PurchaseDiscountPreview? _discountPreview;
  bool _isLoadingDiscountPreview = false;
  bool _hasDiscountPreviewError = false;
  LandedCostAllocationMethod _landedCostAllocationMethod =
      LandedCostAllocationMethod.byLineValue;
  String? _errorMessage;
  int _discountPreviewRequestVersion = 0;
  ProductQuery _query = const ProductQuery(
    availability: ProductAvailabilityFilter.active,
  );

  List<ProductVariant> get variants => List.unmodifiable(_variants);
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
  List<PurchaseLandedCostEntry> get landedCostEntries =>
      List.unmodifiable(_landedCostEntries);
  String get discountCode => _discountCode;
  PurchaseDiscountPreview? get discountPreview => _discountPreview;
  bool get isLoadingDiscountPreview => _isLoadingDiscountPreview;
  bool get hasDiscountPreviewError => _hasDiscountPreviewError;
  double get discountTotal => _discountPreview?.discountTotal ?? 0;
  List<AppliedPurchaseDiscount> get appliedDiscounts =>
      _discountPreview?.appliedDiscounts ?? const [];
  List<String> get unappliedDiscountCodes =>
      _discountPreview?.unappliedDiscountCodes ?? const [];
  LandedCostAllocationMethod get landedCostAllocationMethod =>
      _landedCostAllocationMethod;
  DateTime? get supplierInvoiceDate =>
      _parseSupplierInvoiceDate(_supplierInvoiceDateInput);
  bool get hasInvalidSupplierInvoiceDate =>
      _supplierInvoiceDateInput.trim().isNotEmpty &&
      supplierInvoiceDate == null;
  String? get errorMessage => _errorMessage;
  ProductQuery get query => _query;

  double get subtotal => _draft.fold(0, (sum, line) => sum + line.subtotal);
  double get landedCostTotal =>
      _landedCostEntries.fold(0, (sum, entry) => sum + entry.cost);
  double get total => _discountPreview?.total ?? subtotal + landedCostTotal;
  bool get hasMissingExpiryDates => _draft.any(
    (line) => line.variant.tracksExpiry && line.expiryDate == null,
  );
  bool get canSubmitDraft =>
      _draft.isNotEmpty &&
      _selectedSupplier != null &&
      !hasInvalidSupplierInvoiceDate &&
      !hasMissingExpiryDates &&
      !_isSubmitting;

  PurchaseDiscountPreviewLine? discountPreviewLineForDraftIndex(int index) {
    if (_isLoadingDiscountPreview ||
        _discountPreview == null ||
        index < 0 ||
        index >= _draft.length ||
        index >= _discountPreview!.lines.length) {
      return null;
    }
    final draftLine = _draft[index];
    final previewLine = _discountPreview!.lines[index];
    if (previewLine.variantId != draftLine.variant.id ||
        previewLine.quantity != draftLine.quantity ||
        (previewLine.unitCost - draftLine.unitCost).abs() >= 0.005) {
      return null;
    }
    return previewLine;
  }

  Future<void> loadCatalog() async {
    _isLoading = true;
    _errorMessage = null;
    _nextVariantPage = 1;
    _hasMoreProducts = true;
    notifyListeners();

    final result = await _catalogRepository.loadProductVariants(
      query: _query,
      page: _nextVariantPage,
    );
    switch (result) {
      case Ok<ProductVariantPage>():
        _variants = result.value.variants;
        _hasMoreProducts = result.value.hasMore;
        _nextVariantPage = 2;
      case Error<ProductVariantPage>():
        _variants = _catalogRepository.sampleProductVariants(_query);
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

    final result = await _catalogRepository.loadProductVariants(
      query: _query,
      page: _nextVariantPage,
    );
    switch (result) {
      case Ok<ProductVariantPage>():
        _variants = [..._variants, ...result.value.variants];
        _hasMoreProducts = result.value.hasMore;
        _nextVariantPage += 1;
      case Error<ProductVariantPage>():
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

  Future<ProductVariant?> findVariantByBarcode(String barcode) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return null;
    }

    final result = await _catalogRepository.findProductVariantByBarcode(
      normalizedBarcode,
      activeOnly: true,
    );
    return switch (result) {
      Ok<ProductVariant?>(:final value) => value,
      Error<ProductVariant?>() => throw Exception('barcode lookup failed'),
    };
  }

  Future<ProductVariant?> createQuickProduct(ProductDraft draft) async {
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
        return result.value.defaultVariant;
      case Error<Product>():
        _isCreatingProduct = false;
        notifyListeners();
        return null;
    }
  }

  Future<void> addVariant(
    ProductVariant variant, {
    int quantity = 1,
    double? unitCost,
  }) async {
    if (_isSubmitting) {
      return;
    }

    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      final cost = unitCost ?? await _lastCostForVariant(variant);
      if (_isSubmitting) {
        return;
      }
      _draft.add(
        PurchaseDraftLine(
          variant: variant,
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
    unawaited(refreshDiscountPreview());
  }

  void decrementVariant(ProductVariant variant) {
    if (_isSubmitting) {
      return;
    }

    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
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
    unawaited(refreshDiscountPreview());
  }

  void updateLineCost(ProductVariant variant, double unitCost) {
    if (_isSubmitting || unitCost < 0) {
      return;
    }
    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }
    _lastCostByVariantId[variant.id] = unitCost;
    _draft[index] = _draft[index].copyWith(unitCost: unitCost);
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  void updateLineExpiryDate(ProductVariant variant, DateTime? expiryDate) {
    if (_isSubmitting) {
      return;
    }
    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }
    _draft[index] = _draft[index].copyWith(
      expiryDate: expiryDate,
      clearExpiryDate: expiryDate == null,
    );
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
    _resetLandedCosts();
    _clearDiscountPreview();
    notifyListeners();
  }

  void selectSupplier(SupplierContact? supplier) {
    if (_isSubmitting) {
      return;
    }
    _selectedSupplier = supplier;
    notifyListeners();
    unawaited(refreshDiscountPreview());
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

  void updateDiscountCode(String value) {
    if (_isSubmitting) {
      return;
    }
    _discountCode = value;
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  void updateLandedCostAllocationMethod(LandedCostAllocationMethod method) {
    if (_isSubmitting) {
      return;
    }
    _landedCostAllocationMethod = method;
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  void updateLandedCosts({
    required List<PurchaseLandedCostEntry> entries,
    required LandedCostAllocationMethod allocationMethod,
  }) {
    if (_isSubmitting) {
      return;
    }
    _landedCostEntries = _normalizedLandedCostEntries(entries);
    _landedCostAllocationMethod = allocationMethod;
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  Future<void> refreshDiscountPreview() async {
    final requestVersion = ++_discountPreviewRequestVersion;
    final supplier = _selectedSupplier;
    if (_draft.isEmpty || supplier == null) {
      _discountPreview = null;
      _hasDiscountPreviewError = false;
      _isLoadingDiscountPreview = false;
      notifyListeners();
      return;
    }

    _isLoadingDiscountPreview = true;
    _hasDiscountPreviewError = false;
    notifyListeners();

    final result = await _purchaseRepository.previewDiscounts(
      PurchaseDiscountPreviewDraft.fromDraftLines(
        List<PurchaseDraftLine>.of(_draft),
        supplierId: supplier.id,
        landedCostEntries: _landedCostEntries,
        landedCostAllocationMethod: _landedCostAllocationMethod,
        discountCode: _discountCode,
      ),
    );
    if (requestVersion != _discountPreviewRequestVersion) {
      return;
    }

    switch (result) {
      case Ok<PurchaseDiscountPreview>():
        _discountPreview = result.value;
        _hasDiscountPreviewError = false;
      case Error<PurchaseDiscountPreview>():
        _discountPreview = null;
        _hasDiscountPreviewError = true;
    }
    _isLoadingDiscountPreview = false;
    notifyListeners();
  }

  Future<Result<PurchaseSubmission>> submitDraft() async {
    final supplier = _selectedSupplier;
    if (_draft.isEmpty ||
        supplier == null ||
        hasMissingExpiryDates ||
        _isSubmitting) {
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
      landedCostEntries: _landedCostEntries,
      landedCostAllocationMethod: _landedCostAllocationMethod,
      discountCode: _discountCode,
    );
    switch (result) {
      case Ok<PurchaseSubmission>():
        _draft.clear();
        _selectedSupplier = null;
        _supplierInvoiceNumber = '';
        _supplierInvoiceDateInput = '';
        _discountCode = '';
        _resetLandedCosts();
        _clearDiscountPreview();
      case Error<PurchaseSubmission>():
        break;
    }

    _isSubmitting = false;
    notifyListeners();
    return result;
  }

  void rememberVariantCost(ProductVariant variant, double unitCost) {
    if (unitCost < 0) {
      return;
    }
    _lastCostByVariantId[variant.id] = unitCost;
  }

  Future<double> _lastCostForVariant(ProductVariant variant) async {
    final variantId = variant.id;
    final cached = _lastCostByVariantId[variantId];
    if (cached != null) {
      return cached;
    }

    final result = await _purchaseRepository.loadLastProductCost(
      variant.productId,
      variantId: variantId,
    );
    final cost = switch (result) {
      Ok<double?>(:final value) => value ?? 0,
      Error<double?>() => 0.0,
    };
    _lastCostByVariantId[variantId] = cost;
    return cost;
  }

  void _resetLandedCosts() {
    _landedCostEntries = [];
    _discountCode = '';
    _landedCostAllocationMethod = LandedCostAllocationMethod.byLineValue;
  }

  List<PurchaseLandedCostEntry> _normalizedLandedCostEntries(
    List<PurchaseLandedCostEntry> entries,
  ) {
    return entries
        .where((entry) => entry.name.trim().isNotEmpty && entry.cost > 0)
        .map(
          (entry) => PurchaseLandedCostEntry(
            id: entry.id,
            name: entry.name.trim(),
            cost: entry.cost,
          ),
        )
        .toList(growable: false);
  }

  void _clearDiscountPreview() {
    _discountPreviewRequestVersion += 1;
    _discountPreview = null;
    _hasDiscountPreviewError = false;
    _isLoadingDiscountPreview = false;
  }

  DateTime? _parseSupplierInvoiceDate(String input) {
    final normalized = input.trim().replaceAll('/', '-');
    if (normalized.isEmpty) {
      return null;
    }
    return DateTime.tryParse(normalized);
  }
}
