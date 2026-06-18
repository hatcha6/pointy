import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_draft.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/services/local_scoped_json_storage.dart';

class PurchaseViewModel extends ChangeNotifier {
  PurchaseViewModel(
    this._catalogRepository,
    this._purchaseRepository, {
    AnalyticsEngine? analyticsEngine,
    ScopedJsonStorage draftStorage = const SharedPreferencesScopedJsonStorage(
      'pointy.purchase.draft.v1',
    ),
    String? persistScope,
  }) : _analyticsEngine = analyticsEngine,
       _draftStorage = draftStorage {
    loadCatalog();
    if (persistScope != null) {
      unawaited(restorePersistedDraft(persistScope));
    }
  }

  final CatalogRepository _catalogRepository;
  final PurchaseRepository _purchaseRepository;
  final AnalyticsEngine? _analyticsEngine;
  final ScopedJsonStorage _draftStorage;

  // Local persistence of the in-progress purchase draft.
  String? _persistScope;
  bool _draftRestored = false;
  Timer? _persistDebounce;

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
  String _submitIdempotencyKey = _newPurchaseIdempotencyKey('purchase-draft');
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
    String source = 'purchase_catalog',
  }) async {
    if (_isSubmitting) {
      return;
    }

    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    final previousQuantity = index == -1 ? 0 : _draft[index].quantity;
    if (index == -1) {
      final cost = unitCost ?? await _lastCostForVariant(variant);
      if (_isSubmitting) {
        return;
      }
      final defaultUnit = _defaultPurchaseUnit(variant);
      _draft.add(
        PurchaseDraftLine(
          variant: variant,
          quantity: quantity.clamp(1, 999),
          unitCost: cost,
          unitCode: defaultUnit?.code ?? '',
          unitLabel: defaultUnit?.label ?? '',
          unitFactor: defaultUnit?.factorToBase ?? 1,
        ),
      );
    } else {
      final line = _draft.removeAt(index);
      _draft.add(
        line.copyWith(
          quantity: (line.quantity + quantity).clamp(1, 999),
          unitCost: unitCost,
        ),
      );
    }
    final updatedLine = _draft
        .where((line) => line.variant.id == variant.id)
        .firstOrNull;
    if (updatedLine != null) {
      _trackDraftLineAdded(
        updatedLine,
        addedQuantity: quantity,
        previousQuantity: previousQuantity,
        source: source,
      );
    }
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  void decrementVariant(
    ProductVariant variant, {
    String source = 'purchase_draft_quantity_button',
  }) {
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
      _trackDraftLineDeleted(line, reason: 'decrement_to_zero', source: source);
    } else {
      final updatedLine = line.copyWith(quantity: line.quantity - 1);
      _draft[index] = updatedLine;
      _trackDraftLineQuantityChanged(
        updatedLine,
        previousQuantity: line.quantity,
        newQuantity: updatedLine.quantity,
        reason: 'decrement',
        source: source,
      );
    }
    _touchSubmissionIntent();
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
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  /// Switches the unit a draft line is purchased in. Cost is per unit, so the
  /// discount preview is refreshed.
  void updateLineUnit(
    ProductVariant variant, {
    required String unitCode,
    required String unitLabel,
    required double unitFactor,
  }) {
    if (_isSubmitting) {
      return;
    }
    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }
    _draft[index] = _draft[index].copyWith(
      unitCode: unitCode,
      unitLabel: unitLabel,
      unitFactor: unitFactor,
    );
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  /// The product's configured default purchase unit (if any), resolved from the
  /// variant's embedded product detail. Null = the base unit.
  ProductUnit? _defaultPurchaseUnit(ProductVariant variant) {
    final product = variant.productDetail;
    if (product == null || product.defaultPurchaseUnit.isEmpty) {
      return null;
    }
    for (final unit in product.purchasableUnits) {
      if (unit.code == product.defaultPurchaseUnit) {
        return unit;
      }
    }
    return null;
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
    _touchSubmissionIntent();
    notifyListeners();
  }

  void clearDraft({
    bool trackLineDeletes = true,
    String source = 'purchase_draft_clear_button',
  }) {
    if (_isSubmitting) {
      return;
    }
    final removedLines = trackLineDeletes
        ? List<PurchaseDraftLine>.of(_draft)
        : const <PurchaseDraftLine>[];
    for (final line in removedLines) {
      _trackDraftLineDeleted(line, reason: 'clear_draft', source: source);
    }
    if (removedLines.isNotEmpty) {
      _trackDraftCleared(removedLines, source: source);
    }
    _draft.clear();
    _selectedSupplier = null;
    _supplierInvoiceNumber = '';
    _supplierInvoiceDateInput = '';
    _resetLandedCosts();
    _clearDiscountPreview();
    _touchSubmissionIntent();
    notifyListeners();
  }

  void selectSupplier(SupplierContact? supplier) {
    if (_isSubmitting) {
      return;
    }
    _selectedSupplier = supplier;
    _trackSupplierSelected(supplier);
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  void updateReceiveImmediately(bool value) {
    if (_isSubmitting) {
      return;
    }
    _receiveImmediately = value;
    _touchSubmissionIntent();
    notifyListeners();
  }

  void updateSupplierInvoiceNumber(String value) {
    if (_isSubmitting) {
      return;
    }
    _supplierInvoiceNumber = value;
    _touchSubmissionIntent();
    notifyListeners();
  }

  void updateSupplierInvoiceDateInput(String value) {
    if (_isSubmitting) {
      return;
    }
    _supplierInvoiceDateInput = value;
    _touchSubmissionIntent();
    notifyListeners();
  }

  void updateDiscountCode(String value) {
    if (_isSubmitting) {
      return;
    }
    _discountCode = value;
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  void updateLandedCostAllocationMethod(LandedCostAllocationMethod method) {
    if (_isSubmitting) {
      return;
    }
    _landedCostAllocationMethod = method;
    _touchSubmissionIntent();
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
    _touchSubmissionIntent();
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
      idempotencyKey: _submitIdempotencyKey,
    );
    switch (result) {
      case Ok<PurchaseSubmission>():
        _trackDraftSubmitted(result.value, supplier: supplier);
        _draft.clear();
        _selectedSupplier = null;
        _supplierInvoiceNumber = '';
        _supplierInvoiceDateInput = '';
        _discountCode = '';
        _resetLandedCosts();
        _clearDiscountPreview();
        _touchSubmissionIntent();
      case Error<PurchaseSubmission>():
        _trackDraftSubmitFailed(supplier);
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

  void _touchSubmissionIntent() {
    _submitIdempotencyKey = _newPurchaseIdempotencyKey('purchase-draft');
    _schedulePersist();
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    super.dispose();
  }

  /// Restores the persisted draft for [scope] (the signed-in user id). Safe to
  /// call repeatedly; only re-applies when the scope changes.
  Future<void> restorePersistedDraft(String scope) async {
    if (_draftRestored && _persistScope == scope) {
      return;
    }
    final scopeChanged = _persistScope != null && _persistScope != scope;
    _persistScope = scope;
    _draftRestored = true;
    if (scopeChanged) {
      // Different user on this device — never inherit the previous draft.
      clearDraft(trackLineDeletes: false);
    }

    final raw = await _draftStorage.load(scope);
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final map = decoded.cast<String, Object?>();
      final linesJson = map['lines'];
      if (linesJson is! List) {
        return;
      }
      final lines = <PurchaseDraftLine>[];
      for (final item in linesJson) {
        if (item is! Map) {
          continue;
        }
        try {
          lines.add(PurchaseDraftLine.fromJson(item.cast<String, Object?>()));
        } on FormatException {
          // Skip a corrupt line rather than dropping the whole draft.
        }
      }
      if (lines.isEmpty) {
        return;
      }
      _draft
        ..clear()
        ..addAll(lines);
      final supplierJson = map['supplier'];
      _selectedSupplier = supplierJson is Map
          ? SupplierContact.fromJson(supplierJson.cast<String, Object?>())
          : null;
      _receiveImmediately = map['receiveImmediately'] != false;
      _supplierInvoiceNumber = map['supplierInvoiceNumber']?.toString() ?? '';
      _supplierInvoiceDateInput =
          map['supplierInvoiceDateInput']?.toString() ?? '';
      _discountCode = map['discountCode']?.toString() ?? '';
      final landedJson = map['landedCostEntries'];
      _landedCostEntries = landedJson is List
          ? landedJson
                .whereType<Map>()
                .map(
                  (entry) => PurchaseLandedCostEntry.fromJson(
                    entry.cast<String, Object?>(),
                  ),
                )
                .toList()
          : <PurchaseLandedCostEntry>[];
      _landedCostAllocationMethod = LandedCostAllocationMethod.fromApiValue(
        map['landedCostAllocationMethod'],
      );
      // Fresh idempotency key so a restored draft submits as a new order.
      _submitIdempotencyKey = _newPurchaseIdempotencyKey('purchase-draft');
      notifyListeners();
      if (_selectedSupplier != null) {
        unawaited(refreshDiscountPreview());
      }
    } on FormatException {
      // Corrupt payload — ignore and start fresh.
    }
  }

  void _schedulePersist() {
    final scope = _persistScope;
    if (scope == null) {
      return;
    }
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flushPersist(scope));
    });
  }

  Future<void> _flushPersist(String scope) async {
    if (_draft.isEmpty) {
      await _draftStorage.clear(scope);
      return;
    }
    await _draftStorage.save(scope, _serializeDraft());
  }

  String _serializeDraft() {
    return jsonEncode({
      'version': 1,
      'lines': [for (final line in _draft) line.toJson()],
      'supplier': _selectedSupplier?.toJson(),
      'receiveImmediately': _receiveImmediately,
      'supplierInvoiceNumber': _supplierInvoiceNumber,
      'supplierInvoiceDateInput': _supplierInvoiceDateInput,
      'discountCode': _discountCode,
      'landedCostEntries': [
        for (final entry in _landedCostEntries) entry.toJson(),
      ],
      'landedCostAllocationMethod': _landedCostAllocationMethod.apiValue,
    });
  }

  void _trackDraftLineAdded(
    PurchaseDraftLine line, {
    required int addedQuantity,
    required int previousQuantity,
    required String source,
  }) {
    _trackDraftLineAuditEvent(
      name: previousQuantity == 0
          ? 'purchasing.draft.line.added'
          : 'purchasing.draft.line.quantity_increased',
      severity: AnalyticsEventSeverity.info,
      line: line,
      attributes: {
        'reason': previousQuantity == 0
            ? 'add_to_purchase_draft'
            : 'increment_existing_line',
        'previous_quantity': previousQuantity,
        'new_quantity': line.quantity,
        'added_quantity': addedQuantity,
        'source': source,
      },
      metrics: {
        'quantity': line.quantity,
        'added_quantity': addedQuantity,
        'unit_cost': line.unitCost,
        'line_total': line.subtotal,
      },
    );
  }

  void _trackDraftLineQuantityChanged(
    PurchaseDraftLine line, {
    required int previousQuantity,
    required int newQuantity,
    required String reason,
    required String source,
  }) {
    _trackDraftLineAuditEvent(
      name: 'purchasing.draft.line.quantity_decreased',
      severity: AnalyticsEventSeverity.warning,
      line: line,
      attributes: {
        'reason': reason,
        'previous_quantity': previousQuantity,
        'new_quantity': newQuantity,
        'source': source,
      },
      metrics: {
        'quantity': newQuantity,
        'quantity_delta': newQuantity - previousQuantity,
        'unit_cost': line.unitCost,
        'line_total': line.subtotal,
      },
    );
  }

  void _trackDraftLineDeleted(
    PurchaseDraftLine line, {
    required String reason,
    required String source,
  }) {
    _trackDraftLineAuditEvent(
      name: 'purchasing.draft.line.deleted',
      severity: AnalyticsEventSeverity.warning,
      line: line,
      attributes: {'reason': reason, 'source': source},
      metrics: {
        'quantity': line.quantity,
        'unit_cost': line.unitCost,
        'line_total': line.subtotal,
      },
    );
  }

  void _trackDraftLineAuditEvent({
    required String name,
    required AnalyticsEventSeverity severity,
    required PurchaseDraftLine line,
    required Map<String, Object?> attributes,
    required Map<String, num> metrics,
  }) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: name,
          severity: severity,
          entityType: 'purchase_draft_line',
          entityId: '${line.variant.id}',
          attributes: {
            ...attributes,
            'supplier_id': _selectedSupplier?.id,
            'supplier_name': _selectedSupplier?.name,
            'product_id': line.variant.productId,
            'variant_id': line.variant.id,
            'product_name': line.variant.productLabel,
            'variant_name': line.variant.variantLabel,
            'sku': line.variant.sku,
            'draft_line_count': _draft.length,
            'draft_item_count': _draftItemCount(_draft),
            'draft_total': _draftTotal(_draft),
          },
          metrics: {
            ...metrics,
            'draft_line_count': _draft.length,
            'draft_item_count': _draftItemCount(_draft),
            'draft_total': _draftTotal(_draft),
          },
        ),
      ),
    );
  }

  void _trackDraftCleared(
    List<PurchaseDraftLine> removedLines, {
    required String source,
  }) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'purchasing.draft.cleared',
          severity: AnalyticsEventSeverity.warning,
          entityType: 'purchase_draft',
          attributes: {
            'supplier_id': _selectedSupplier?.id,
            'supplier_name': _selectedSupplier?.name,
            'source': source,
            'line_count': removedLines.length,
            'item_count': _draftItemCount(removedLines),
            'draft_total': _draftTotal(removedLines),
            'lines': _draftLineSnapshots(removedLines),
          },
          metrics: {
            'line_count': removedLines.length,
            'item_count': _draftItemCount(removedLines),
            'draft_total': _draftTotal(removedLines),
          },
        ),
      ),
    );
  }

  void _trackSupplierSelected(SupplierContact? supplier) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null || supplier == null) {
      return;
    }
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'purchasing.draft.supplier.selected',
          entityType: 'supplier',
          entityId: '${supplier.id}',
          attributes: {
            'supplier_id': supplier.id,
            'supplier_name': supplier.name,
            'draft_line_count': _draft.length,
            'draft_item_count': _draftItemCount(_draft),
            'draft_total': _draftTotal(_draft),
          },
          metrics: {
            'draft_line_count': _draft.length,
            'draft_item_count': _draftItemCount(_draft),
            'draft_total': _draftTotal(_draft),
          },
        ),
      ),
    );
  }

  void _trackDraftSubmitted(
    PurchaseSubmission submission, {
    required SupplierContact supplier,
  }) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    final draftSnapshot = List<PurchaseDraftLine>.of(_draft);
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'purchasing.draft.submitted',
          entityType: 'purchase_draft',
          entityId: submission.draftNumber,
          attributes: {
            'draft_number': submission.draftNumber,
            'order_number': submission.draftNumber,
            'submission_status': submission.status,
            'supplier_id': supplier.id,
            'supplier_name': supplier.name,
            'receive_immediately': _receiveImmediately,
            'supplier_invoice_number_present': _supplierInvoiceNumber
                .trim()
                .isNotEmpty,
            'discount_code_present': _discountCode.trim().isNotEmpty,
            'line_count': draftSnapshot.length,
            'item_count': _draftItemCount(draftSnapshot),
            'draft_total': _draftTotal(draftSnapshot),
            'purchase_total': submission.total,
            'lines': _draftLineSnapshots(draftSnapshot),
          },
          metrics: {
            'line_count': draftSnapshot.length,
            'item_count': _draftItemCount(draftSnapshot),
            'draft_total': _draftTotal(draftSnapshot),
            'purchase_total': submission.total,
          },
        ),
      ),
    );
  }

  void _trackDraftSubmitFailed(SupplierContact supplier) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'purchasing.draft.submit_failed',
          severity: AnalyticsEventSeverity.error,
          entityType: 'supplier',
          entityId: '${supplier.id}',
          attributes: {
            'supplier_id': supplier.id,
            'supplier_name': supplier.name,
            'line_count': _draft.length,
            'item_count': _draftItemCount(_draft),
            'draft_total': _draftTotal(_draft),
            'lines': _draftLineSnapshots(_draft),
          },
          metrics: {
            'line_count': _draft.length,
            'item_count': _draftItemCount(_draft),
            'draft_total': _draftTotal(_draft),
          },
        ),
      ),
    );
  }

  List<Map<String, Object?>> _draftLineSnapshots(
    List<PurchaseDraftLine> lines,
  ) {
    return [
      for (final line in lines.take(50))
        {
          'product_id': line.variant.productId,
          'variant_id': line.variant.id,
          'product_name': line.variant.productLabel,
          'variant_name': line.variant.variantLabel,
          'sku': line.variant.sku,
          'quantity': line.quantity,
          'unit_cost': line.unitCost,
          'line_total': line.subtotal,
        },
    ];
  }

  int _draftItemCount(List<PurchaseDraftLine> lines) {
    return lines.fold(0, (sum, line) => sum + line.quantity);
  }

  double _draftTotal(List<PurchaseDraftLine> lines) {
    return lines.fold(0, (sum, line) => sum + line.subtotal);
  }

  DateTime? _parseSupplierInvoiceDate(String input) {
    final normalized = input.trim().replaceAll('/', '-');
    if (normalized.isEmpty) {
      return null;
    }
    return DateTime.tryParse(normalized);
  }
}

String _newPurchaseIdempotencyKey(String scope) {
  return '$scope:${generateAnalyticsEventId()}';
}
