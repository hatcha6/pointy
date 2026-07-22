import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/barcode_resolution.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/services/local_scoped_json_storage.dart';
import '../../../shared/units.dart';

/// Add sources that mark the new line as the active line for the arrow-key
/// unit cycle, exactly like a hardware scan does — so picking a product from
/// the catalog then tapping an arrow cycles that line's unit with no extra tap.
const _activeLineAddSources = {
  'purchase_barcode_lookup',
  'purchase_catalog_tile',
  'purchase_catalog',
};

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
  AnalyticsEngine? get analyticsEngine => _analyticsEngine;

  List<ProductVariant> _variants = [];
  final List<PurchaseDraftLine> _draft = [];
  final Map<int, double> _lastCostByVariantId = {};

  // The draft line the arrow-key unit cycle acts on: the last line a scan or
  // catalog tap landed on. A hardware scan never touches a line's quantity — it
  // only ever adds/increments its own product.
  int? _lastScannedVariantId;

  /// Non-null when this workspace is editing an existing draft purchase order
  /// (its id) rather than building a brand-new one. Drives "save" vs "submit"
  /// semantics and the screen's labels.
  int? _editingOrderId;

  /// Lines from the edited order whose product/variant could no longer be
  /// resolved from the catalog (archived or deleted). Surfaced as a warning so
  /// the user knows the reopened draft is missing items.
  final List<String> _unresolvedEditLineNames = [];
  SupplierContact? _selectedSupplier;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSubmitting = false;
  bool _receiveImmediately = true;
  bool _hasMoreProducts = true;
  int _nextVariantPage = 1;
  // Monotonic token so a fast typist's superseded catalog request can't land its
  // (stale, out-of-order) results over a newer one — matches the POS guard.
  int _catalogRequestVersion = 0;
  String _supplierInvoiceNumber = '';
  String _supplierInvoiceDateInput = '';
  List<PurchaseLandedCostEntry> _landedCostEntries = [];
  String _discountCode = '';
  double _extraDiscount = 0;
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

  /// Whether this workspace is editing a saved draft purchase order.
  bool get isEditing => _editingOrderId != null;
  int? get editingOrderId => _editingOrderId;
  List<String> get unresolvedEditLineNames =>
      List.unmodifiable(_unresolvedEditLineNames);
  SupplierContact? get selectedSupplier => _selectedSupplier;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSubmitting => _isSubmitting;
  bool get receiveImmediately => _receiveImmediately;
  bool get hasMoreProducts => _hasMoreProducts;
  String get supplierInvoiceNumber => _supplierInvoiceNumber;
  String get supplierInvoiceDateInput => _supplierInvoiceDateInput;
  List<PurchaseLandedCostEntry> get landedCostEntries =>
      List.unmodifiable(_landedCostEntries);
  String get discountCode => _discountCode;

  /// One-off order discount typed by hand (mostly a fraction eliminator).
  double get extraDiscount => _extraDiscount;
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

  /// Whether the edited draft can be saved. Unlike submitting, saving a draft
  /// does not require expiry dates — those only become mandatory at submit time
  /// (mirroring the backend, which only enforces them on submit).
  bool get canSaveDraft =>
      isEditing &&
      _draft.isNotEmpty &&
      _selectedSupplier != null &&
      !hasInvalidSupplierInvoiceDate &&
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
    final requestVersion = ++_catalogRequestVersion;
    notifyListeners();

    final result = await _catalogRepository.loadProductVariants(
      query: _query,
      page: _nextVariantPage,
    );
    if (requestVersion != _catalogRequestVersion) {
      // A newer search started while this was in flight; drop the stale result.
      return;
    }
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
    final requestVersion = _catalogRequestVersion;
    notifyListeners();

    final result = await _catalogRepository.loadProductVariants(
      query: _query,
      page: _nextVariantPage,
    );
    if (requestVersion != _catalogRequestVersion) {
      // A new search replaced this catalog while the page was loading.
      return;
    }
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
    final result = await resolveBarcode(barcode);
    // Packaging (unit) barcodes land on the product's default variant here —
    // the draft line then opens in the product's default purchase unit.
    return switch (result) {
      Ok<BarcodeResolution?>(:final value) => value?.variant,
      Error<BarcodeResolution?>(:final exception) => throw exception,
    };
  }

  /// Resolves a scanned code to its variant and, for packaging barcodes (the
  /// carton EAN), the matched unit — so the draft line is created in cartons.
  /// A lookup failure surfaces as [Error] so callers can tell an unreadable
  /// code from a genuinely missing product (the quick-create offer).
  Future<Result<BarcodeResolution?>> resolveBarcode(String barcode) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return const Ok(null);
    }

    return _catalogRepository.resolveBarcode(
      normalizedBarcode,
      activeOnly: true,
    );
  }

  Future<void> addVariant(
    ProductVariant variant, {
    double quantity = 1,
    double? unitCost,
    ProductUnit? unit,
    String source = 'purchase_catalog',
  }) async {
    if (_isSubmitting) {
      return;
    }

    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    final previousQuantity = index == -1 ? 0.0 : _draft[index].quantity;
    if (index == -1) {
      // A scanned packaging barcode dictates the line's unit; otherwise the
      // product's configured default purchase unit applies.
      final lineUnit = (unit != null && unit.isPurchasable)
          ? unit
          : _defaultPurchaseUnit(variant);
      final lineFactor = lineUnit?.factorToBase ?? 1;
      // The fetched cost is per BASE unit; the line's cost is per its own
      // unit, so a carton line starts at base × pieces-per-carton. An
      // explicitly passed cost is already in the line's unit.
      final cost =
          unitCost ?? (await _lastCostForVariant(variant)) * lineFactor;
      if (_isSubmitting) {
        return;
      }
      _draft.add(
        PurchaseDraftLine(
          variant: variant,
          quantity: _clampQuantity(quantity),
          unitCost: cost,
          unitCode: lineUnit?.code ?? '',
          unitLabel: lineUnit?.label ?? '',
          unitFactor: lineFactor,
          unitAllowsFractional: _unitAllowsFractional(variant, lineUnit),
        ),
      );
    } else {
      // The draft keeps one line per variant: repeat adds bump the quantity in
      // the line's existing unit (switch units from the line's unit chip).
      // Updated in place — a line's position is set on first insertion and
      // never changes afterwards.
      final line = _draft[index];
      _draft[index] = line.copyWith(
        quantity: _clampQuantity(line.quantity + quantity),
        unitCost: unitCost,
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
    if (_activeLineAddSources.contains(source)) {
      // Mark the line the add landed on as the active line for the arrow-key
      // unit cycle — scanning and picking from the catalog behave the same.
      _lastScannedVariantId = variant.id;
    }
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  /// The draft line the last scan or catalog tap landed on, if it is still in
  /// the draft — the target of the arrow-key unit cycle.
  PurchaseDraftLine? get lastScannedDraftLine {
    final variantId = _lastScannedVariantId;
    if (variantId == null) {
      return null;
    }
    return _draft.where((line) => line.variant.id == variantId).firstOrNull;
  }

  /// Sets a draft line's quantity outright (the scan-then-type flow and the
  /// quantity editor; the steppers keep using [addVariant]/[decrementVariant]).
  /// Any product may be purchased in a fractional quantity — the buyer's choice.
  void setLineQuantity(
    ProductVariant variant,
    double quantity, {
    String source = 'purchase_quantity_edit',
  }) {
    if (_isSubmitting || quantity <= 0) {
      return;
    }
    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }
    final line = _draft[index];
    final clamped = _clampQuantity(quantity);
    if (line.quantity == clamped) {
      return;
    }
    final updatedLine = line.copyWith(quantity: clamped);
    _draft[index] = updatedLine;
    _trackDraftLineQuantityChanged(
      updatedLine,
      previousQuantity: line.quantity,
      newQuantity: clamped,
      reason: 'quantity_edit',
      source: source,
    );
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  /// Draft quantities live in 0.001–999999.999 (3dp, matching the backend).
  static double _clampQuantity(double quantity) {
    final clamped = quantity.clamp(0.001, 999999.999);
    return (clamped * 1000).roundToDouble() / 1000;
  }

  /// Whether [unit] (or the base unit when null) transacts in fractions.
  bool _unitAllowsFractional(ProductVariant variant, ProductUnit? unit) {
    if (unit != null) {
      return unit.allowsFractional;
    }
    final baseUnit = variant.productDetail?.unit ?? variant.unit;
    return baseUnitAllowsFractional(baseUnit);
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
    // The cache is per BASE unit (that's what addVariant multiplies by the new
    // line's factor); the entered cost is per this line's unit, so a carton's
    // 162 must be stored as 162/30 — not poison the next piece-line prefill.
    final factor = _draft[index].unitFactor;
    _lastCostByVariantId[variant.id] = factor > 0 ? unitCost / factor : unitCost;
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
    bool allowsFractional = false,
  }) {
    if (_isSubmitting) {
      return;
    }
    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }
    final line = _draft[index];
    // A typed fraction survives a unit switch — any unit may transact in
    // fractions now, so the quantity carries over untouched.
    // The cost is per the line's unit: switching carton → tray rescales it
    // proportionally (162 per carton of 12 trays → 13.50 per tray), keeping
    // hand-entered costs meaningful across unit changes.
    final previousFactor = line.unitFactor <= 0 ? 1.0 : line.unitFactor;
    final newFactor = unitFactor <= 0 ? 1.0 : unitFactor;
    final rescaledCost = double.parse(
      (line.unitCost / previousFactor * newFactor).toStringAsFixed(2),
    );
    _draft[index] = line.copyWith(
      quantity: line.quantity,
      unitCost: rescaledCost,
      unitCode: unitCode,
      unitLabel: unitLabel,
      unitFactor: unitFactor,
      unitAllowsFractional: allowsFractional,
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
    // Soft-boost this supplier's products to the top of the catalog (it does not
    // hide the rest) so the buyer's usual items surface first. Reload only when
    // the boost actually changed.
    final boosted = _query.withPreferredSupplier(supplier?.id);
    if (boosted != _query) {
      _query = boosted;
      unawaited(loadCatalog());
    }
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

  void updateExtraDiscount(double value) {
    if (_isSubmitting || value < 0) {
      return;
    }
    _extraDiscount = value;
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
        extraDiscountAmount: _extraDiscount,
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
      extraDiscountAmount: _extraDiscount,
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

  /// Reopens an existing **draft** purchase [order] in this workspace for
  /// editing. Reconstructs the draft lines — resolving each line's full product
  /// variant from the catalog so units, pricing and expiry behave exactly like
  /// a fresh draft — along with the supplier, invoice details, landed costs and
  /// discount. Lines whose product can no longer be resolved (archived/deleted)
  /// are dropped and recorded in [unresolvedEditLineNames] so the UI can warn.
  Future<void> loadOrderForEditing(PurchaseOrder order) async {
    _editingOrderId = order.id;
    _unresolvedEditLineNames.clear();
    final supplierId = order.supplierId;
    _selectedSupplier = supplierId == null
        ? null
        : SupplierContact(
            id: supplierId,
            name: order.supplierName ?? '',
            contactName: order.supplierContactName ?? '',
            phone: order.supplierPhone ?? '',
            email: order.supplierEmail ?? '',
            address: order.supplierAddress ?? '',
            notes: '',
            isActive: true,
          );
    _supplierInvoiceNumber = order.supplierInvoiceNumber;
    _supplierInvoiceDateInput = order.supplierInvoiceDate == null
        ? ''
        : order.supplierInvoiceDate!.toIso8601String().split('T').first;
    // The draft pane edits a single coupon; a draft from the purchasing flow
    // only ever carries one.
    _discountCode = order.discountCodes.isEmpty
        ? ''
        : order.discountCodes.first;
    _landedCostEntries = _normalizedLandedCostEntries(order.landedCostEntries);
    _landedCostAllocationMethod = order.landedCostAllocationMethod;
    _extraDiscount = order.extraDiscountAmount;
    // Receiving-on-submit is a submit-time concern; editing only saves a draft.
    _receiveImmediately = false;
    _submitIdempotencyKey = _newPurchaseIdempotencyKey('purchase-edit');

    final lines = await _draftLinesForOrder(order);
    _draft
      ..clear()
      ..addAll(lines);
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  /// Persists edits to the reopened draft order without committing it — the
  /// order stays a draft, ready to be submitted later from its details screen.
  /// Returns an error result (and is a no-op) unless [isEditing].
  Future<Result<PurchaseOrder>> saveDraft() async {
    final supplier = _selectedSupplier;
    final orderId = _editingOrderId;
    if (orderId == null ||
        _draft.isEmpty ||
        supplier == null ||
        hasInvalidSupplierInvoiceDate ||
        _isSubmitting) {
      return Error(Exception('purchase draft is not ready to save'));
    }

    _isSubmitting = true;
    notifyListeners();

    final result = await _purchaseRepository.updateDraftOrder(
      orderId,
      List.of(_draft),
      supplierId: supplier.id,
      supplierInvoiceNumber: _supplierInvoiceNumber,
      supplierInvoiceDate: supplierInvoiceDate,
      landedCostEntries: _landedCostEntries,
      landedCostAllocationMethod: _landedCostAllocationMethod,
      discountCode: _discountCode,
      extraDiscountAmount: _extraDiscount,
    );
    switch (result) {
      case Ok<PurchaseOrder>():
        _trackDraftSaved(result.value, supplier: supplier);
      case Error<PurchaseOrder>():
        _trackDraftSubmitFailed(supplier);
    }

    _isSubmitting = false;
    notifyListeners();
    return result;
  }

  Future<List<PurchaseDraftLine>> _draftLinesForOrder(
    PurchaseOrder order,
  ) async {
    final productIds = <int>{
      for (final line in order.lines) line.productId,
    }.toList(growable: false);
    final products = <int, Product>{};
    final results = await Future.wait(
      productIds.map(_catalogRepository.loadProduct),
    );
    for (var i = 0; i < productIds.length; i += 1) {
      if (results[i] case Ok<Product>(:final value)) {
        products[productIds[i]] = value;
      }
    }

    final lines = <PurchaseDraftLine>[];
    for (final line in order.lines) {
      final draftLine = _draftLineForOrderLine(line, products[line.productId]);
      if (draftLine == null) {
        _unresolvedEditLineNames.add(
          line.displayName.isEmpty
              ? line.variantSku ?? '#${line.variantId}'
              : line.displayName,
        );
      } else {
        lines.add(draftLine);
      }
    }
    return lines;
  }

  PurchaseDraftLine? _draftLineForOrderLine(
    PurchaseOrderLine line,
    Product? product,
  ) {
    final variant = _resolveVariantForLine(line, product);
    if (variant == null) {
      return null;
    }
    final unit = _resolvePurchaseUnit(product, line.unit);
    return PurchaseDraftLine(
      variant: variant,
      quantity: line.quantity.clamp(1, 999),
      unitCost: line.unitCost,
      // Keep the order's unit even if it can no longer be resolved, so the
      // saved line still round-trips the same purchase unit to the backend.
      unitCode: unit?.code ?? line.unit,
      unitLabel: unit?.label ?? line.unitLabel,
      unitFactor: unit?.factorToBase ?? 1,
      expiryDate: line.expiryDate,
    );
  }

  ProductVariant? _resolveVariantForLine(
    PurchaseOrderLine line,
    Product? product,
  ) {
    if (product == null) {
      return null;
    }
    ProductVariant? match;
    for (final variant in product.variants) {
      if (variant.id == line.variantId) {
        match = variant;
        break;
      }
    }
    final defaultVariant = product.defaultVariant;
    if (match == null &&
        defaultVariant != null &&
        defaultVariant.id == line.variantId) {
      match = defaultVariant;
    }
    if (match == null) {
      return null;
    }
    // Variants embedded in a product detail omit the product back-reference the
    // draft tile relies on for unit/expiry resolution — attach it.
    return match.productDetail == null
        ? match.copyWith(productDetail: product)
        : match;
  }

  ProductUnit? _resolvePurchaseUnit(Product? product, String unitCode) {
    if (product == null || unitCode.isEmpty) {
      return null;
    }
    for (final unit in product.purchasableUnits) {
      if (unit.code == unitCode) {
        return unit;
      }
    }
    // The unit may have been made non-purchasable since the draft was created;
    // still honour the snapshot if the product knows the conversion.
    for (final unit in product.units) {
      if (unit.code == unitCode) {
        return unit;
      }
    }
    return null;
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

  /// The sibling variants of a purchase line's product — the reprice dialog
  /// lists them all so a cost change can update every variant's selling price.
  Future<List<ProductVariant>> loadSiblingVariants(int productId) async {
    final result = await _catalogRepository.loadVariantsForProduct(productId);
    return switch (result) {
      Ok<ProductVariantPage>(:final value) => value.variants,
      Error<ProductVariantPage>() => const <ProductVariant>[],
    };
  }

  /// Suggested sale price for [unitCost], offered in the reprice dialog when a
  /// line's cost changes. Pass [productId] so the suggestion uses the markup of
  /// that product's own category (its real pricing strategy) when there's enough
  /// data, falling back to the shop-wide markup.
  Future<({double? suggestedPrice, double? markupPercent})>
  loadPricingSuggestion(double unitCost, {int? productId}) async {
    final result = await _purchaseRepository.loadPricingSuggestion(
      unitCost,
      productId: productId,
    );
    return switch (result) {
      Ok<({double? suggestedPrice, double? markupPercent})>(:final value) =>
        value,
      Error<({double? suggestedPrice, double? markupPercent})>() => (
        suggestedPrice: null,
        markupPercent: null,
      ),
    };
  }

  /// Writes new selling prices for a product's variants (the reprice dialog).
  /// Only the entries in [pricesByVariant] are changed. Returns success.
  Future<bool> repriceProductVariants(
    int productId,
    Map<int, double> pricesByVariant,
  ) async {
    if (pricesByVariant.isEmpty) {
      return true;
    }
    final result = await _catalogRepository.setVariantPrices(
      productId: productId,
      pricesByVariant: pricesByVariant,
    );
    return result is Ok<Product>;
  }

  void _resetLandedCosts() {
    _landedCostEntries = [];
    _discountCode = '';
    _extraDiscount = 0;
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
    required double addedQuantity,
    required double previousQuantity,
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
    required double previousQuantity,
    required double newQuantity,
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

  void _trackDraftSaved(
    PurchaseOrder order, {
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
          name: 'purchasing.draft.saved',
          entityType: 'purchase_order',
          entityId: '${order.id}',
          attributes: {
            'order_id': order.id,
            'order_number': order.orderNumber,
            'supplier_id': supplier.id,
            'supplier_name': supplier.name,
            'line_count': draftSnapshot.length,
            'item_count': _draftItemCount(draftSnapshot),
            'draft_total': _draftTotal(draftSnapshot),
            'lines': _draftLineSnapshots(draftSnapshot),
          },
          metrics: {
            'line_count': draftSnapshot.length,
            'item_count': _draftItemCount(draftSnapshot),
            'draft_total': _draftTotal(draftSnapshot),
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

  double _draftItemCount(List<PurchaseDraftLine> lines) {
    return lines.fold(0.0, (sum, line) => sum + line.quantity);
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
