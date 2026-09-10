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
import '../../../data/models/purchase_suggestion.dart';
import '../../../data/models/exchange_rate.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/fx_repository.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/repositories/warehouse_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/services/local_scoped_json_storage.dart';
import '../../../shared/formatters.dart';
import '../../../shared/units.dart';
import '../../../data/models/purchase_cost_warning.dart';
import '../../../data/services/api_error_detail.dart';
import 'purchase_suggestion_controller.dart';

/// Add sources that mark the new line as the active line for the arrow-key
/// unit cycle, exactly like a hardware scan does — so picking a product from
/// the catalog then tapping an arrow cycles that line's unit with no extra tap.
const _activeLineAddSources = {
  'purchase_barcode_lookup',
  'purchase_catalog_tile',
  'purchase_catalog',
};

/// Lets the purchase view model ask the catalog search field to reclaim
/// keyboard focus at the buyer's natural resting points — a product added from
/// the grid, a scan resolved, a line deleted — so the next code can be scanned
/// or typed without a tap. The POS has had this since the search-autofocus work;
/// purchasing is the same job (a buyer scanning a delivery in, one box after
/// another) and was simply left behind.
///
/// A pure signal: the search field decides whether taking focus is appropriate
/// right now (never while a sheet or dialog is up, never on a phone layout).
class PurchaseSearchFocusController extends ChangeNotifier {
  void requestFocus() => notifyListeners();
}

/// Tells the catalog search field to hard-reset: clear its text AND cancel any
/// in-flight debounce. Fired after every scan — the wedge burst lands in the
/// focused field and starts a debounced search which, without this, fires
/// ~350ms later and pushes the barcode back into the box.
class PurchaseSearchResetController extends ChangeNotifier {
  void requestReset() => notifyListeners();
}

/// Where a scan got to, mirrored on the catalog pane's status line so a buyer
/// working a stack of boxes can see the scanner is being heard without watching
/// the draft scroll.
enum PurchaseScanStatus { idle, resolving, found, notFound, error }

/// A line lifted out of the draft, with where it sat — enough to put it back
/// exactly, so deleting a line is always one tap from undone.
class RemovedPurchaseDraftLine {
  const RemovedPurchaseDraftLine(this.line, this.index);

  final PurchaseDraftLine line;
  final int index;
}

class PurchaseViewModel extends ChangeNotifier {
  PurchaseViewModel(
    this._catalogRepository,
    this._purchaseRepository, {
    AnalyticsEngine? analyticsEngine,
    this.discountPreviewDebounce = const Duration(milliseconds: 250),
    ScopedJsonStorage draftStorage = const SharedPreferencesScopedJsonStorage(
      'pointy.purchase.draft.v1',
    ),
    String? persistScope,
    FxRepository? fxRepository,
    WarehouseRepository? warehouseRepository,
    PurchaseSuggestionController? suggestionController,
  }) : _analyticsEngine = analyticsEngine,
       _warehouseRepository = warehouseRepository,
       _fxRepository = fxRepository,
       _draftStorage = draftStorage,
       suggestions =
           suggestionController ??
           PurchaseSuggestionController(repository: _purchaseRepository) {
    suggestions.addListener(notifyListeners);
    loadCatalog();
    unawaited(loadSupplierCurrencies());
    if (persistScope != null) {
      unawaited(restorePersistedDraft(persistScope));
    }
  }

  final CatalogRepository _catalogRepository;
  final PurchaseRepository _purchaseRepository;

  /// The suggestion strip's own state. Owned here so the whole purchasing
  /// screen sees one answer, but deliberately a separate object: nothing it
  /// does may block, slow or fail a draft edit.
  final PurchaseSuggestionController suggestions;
  final AnalyticsEngine? _analyticsEngine;

  /// Optional so every existing construction site keeps working. Without it the
  /// purchasing screen never offers a supplier currency, which is right for a
  /// shop with no foreign suppliers.
  final FxRepository? _fxRepository;
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

  /// What the shop last PAID per base unit, as the server reported it. Distinct
  /// from [_lastCostByVariantId], which the cost field overwrites as the buyer
  /// types (so the next line of the same product prefills from what they just
  /// entered). This one is only ever written from a server read, so the line's
  /// "cost moved" comparison stays anchored to the previous purchase instead of
  /// chasing the number being typed.
  final Map<int, double> _previousBaseCostByVariantId = {};

  final PurchaseSearchFocusController _searchFocusController =
      PurchaseSearchFocusController();
  final PurchaseSearchResetController _searchResetController =
      PurchaseSearchResetController();
  PurchaseScanStatus _scanStatus = PurchaseScanStatus.idle;
  String? _lastScannedBarcode;
  String? _lastScannedProductName;

  // The draft line the arrow-key unit cycle acts on: the last line a scan or
  // catalog tap landed on. A hardware scan never touches a line's quantity — it
  // only ever adds/increments its own product.
  int? _lastScannedVariantId;

  /// Non-null when this workspace is editing an existing draft purchase order
  /// (its id) rather than building a brand-new one. Drives "save" vs "submit"
  /// semantics and the screen's labels.
  int? _editingOrderId;

  /// The status the edited order carried when it was opened. Editing anything
  /// past `draft` re-applies its expected stock — and, once it has been
  /// delivered, its receipt — so the save is held to the submit-time rules.
  String _editingOrderStatus = '';

  /// Lines from the edited order whose product/variant could no longer be
  /// resolved from the catalog (archived or deleted). Surfaced as a warning so
  /// the user knows the reopened draft is missing items.
  final List<String> _unresolvedEditLineNames = [];
  SupplierContact? _selectedSupplier;

  /// Where this purchase will land. Null means the shop's own place, which is
  /// what a shop with one warehouse always means and never has to say.
  Warehouse? _selectedWarehouse;

  /// The shop's places, loaded once. Empty or single means the picker is never
  /// shown: there is nothing to choose between.
  List<Warehouse> _warehouses = const [];
  final WarehouseRepository? _warehouseRepository;
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

  /// The currency the SUPPLIER invoiced in; blank = the shop's own, which is
  /// every order unless the buyer says otherwise.
  String _currencyCode = '';

  /// A rate the buyer typed. Null lets the server read the rate as of the
  /// supplier's invoice date — the number the invoice was actually priced at.
  double? _typedExchangeRate;
  List<Currency> _currencies = const <Currency>[];
  CurrentRates _rates = CurrentRates.empty;
  bool _hasLoadedCurrencies = false;
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

  /// How long the draft must sit still before a discount preview is asked
  /// for. Every line edit re-previews; while a buyer types a quantity or
  /// holds a +/− key the draft changes many times a second, and the field
  /// measured a third of all purchasing previews arriving within half a
  /// second of the previous one — each a full engine pass on the server.
  /// One request per pause instead of one per keystroke.
  final Duration discountPreviewDebounce;
  Timer? _discountPreviewDebounceTimer;
  Completer<void>? _discountPreviewSettled;
  // Guards the one-shot selling-price refresh a restored draft kicks off, so a
  // second restore (or a rebuild) can never double-fetch.
  bool _isRefreshingSellingPrices = false;
  bool _disposed = false;
  ProductQuery _query = const ProductQuery(
    availability: ProductAvailabilityFilter.active,
  );

  List<ProductVariant> get variants => List.unmodifiable(_variants);
  List<PurchaseDraftLine> get draft => List.unmodifiable(_draft);

  /// Whether this workspace is editing a saved draft purchase order.
  bool get isEditing => _editingOrderId != null;
  int? get editingOrderId => _editingOrderId;

  /// Editing an order that has already been submitted: expected stock is
  /// rebuilt on save, so expiry dates are due now rather than at submit.
  bool get isEditingCommittedOrder =>
      isEditing &&
      _editingOrderStatus.isNotEmpty &&
      _editingOrderStatus != 'draft';

  /// Editing an order whose goods are already on the shelf. Saving unwinds the
  /// delivery and records it again against the corrected lines.
  bool get isEditingReceivedOrder =>
      isEditing &&
      const {
        'received',
        'partially_received',
        'partial',
      }.contains(_editingOrderStatus);
  List<String> get unresolvedEditLineNames =>
      List.unmodifiable(_unresolvedEditLineNames);
  SupplierContact? get selectedSupplier => _selectedSupplier;
  Warehouse? get selectedWarehouse => _selectedWarehouse;
  List<Warehouse> get warehouses => _warehouses;

  /// Whether the buyer is offered a choice at all.
  bool get canChooseWarehouse => _warehouses.length > 1;

  void selectWarehouse(Warehouse? warehouse) {
    if (_selectedWarehouse?.id == warehouse?.id) {
      return;
    }
    _selectedWarehouse = warehouse;
    notifyListeners();
  }

  /// Best effort: a buyer who cannot load the shop's places still writes a
  /// purchase order, it simply lands in the default one.
  Future<void> loadWarehouses() async {
    final repository = _warehouseRepository;
    if (repository == null) {
      return;
    }
    final result = await repository.loadWarehouses(activeOnly: true);
    if (result case Ok<List<Warehouse>>()) {
      _warehouses = result.value.where((place) => place.sellsFrom).toList();
      _selectedWarehouse ??= _warehouses.where((p) => p.isDefault).firstOrNull;
      notifyListeners();
    }
  }
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSubmitting => _isSubmitting;
  bool get receiveImmediately => _receiveImmediately;
  bool get hasMoreProducts => _hasMoreProducts;
  String get supplierInvoiceNumber => _supplierInvoiceNumber;

  String get currencyCode => _currencyCode;
  double? get typedExchangeRate => _typedExchangeRate;
  bool get isForeignCurrency => _currencyCode.isNotEmpty;
  String get baseCurrencyCode => _rates.baseCode;

  /// Currencies a supplier may invoice in — everything enabled except the
  /// shop's own. Empty on a shop with no FX feed, which keeps the picker hidden.
  List<Currency> get supplierCurrencies => _currencies
      .where((c) => c.isEnabled && c.code != _rates.baseCode)
      .toList();

  /// The rate that would be used for the current currency, or null when none is
  /// known — in which case the buyer must type one.
  ResolvedRate? get currentRate =>
      _currencyCode.isEmpty ? null : _rates.rateFor(_currencyCode);

  /// The rate the order will actually be costed at: what the buyer typed, else
  /// what the feed knows. Null means the order cannot be costed yet.
  double? get effectiveRate => _typedExchangeRate ?? currentRate?.rate;

  /// The draft total as the supplier invoiced it, for checking against the
  /// paper invoice. The stored total stays in the shop's own currency.
  double get foreignDraftTotal => _draft.fold<double>(
    0,
    (sum, line) => sum + line.unitCost * line.quantity,
  );

  /// Loads the currency registry once. Silent on failure: not reaching the rate
  /// endpoint is no reason to stop somebody recording a purchase — the picker
  /// simply does not appear and the order is in the shop's own currency.
  Future<void> loadSupplierCurrencies() async {
    if (_hasLoadedCurrencies || _fxRepository == null) {
      return;
    }
    _hasLoadedCurrencies = true;
    final ratesResult = await _fxRepository.loadCurrentRates();
    if (ratesResult case Ok<CurrentRates>(value: final loaded)) {
      _rates = loaded;
    }
    // Same master switch as the product form: a single-currency shop is never
    // shown a supplier-currency picker.
    if (!_rates.fxEnabled) {
      notifyListeners();
      return;
    }

    final currenciesResult = await _fxRepository.loadCurrencies();
    if (currenciesResult case Ok<List<Currency>>(value: final loaded)) {
      configureForeignCurrencySymbols(<String, String>{
        for (final currency in loaded) currency.code: currency.symbol,
      });
      _currencies = loaded;
    }
    notifyListeners();
  }

  void updateCurrencyCode(String value) {
    if (_isSubmitting) {
      return;
    }
    _currencyCode = value.trim().toUpperCase();
    // A rate typed for the old currency means nothing for the new one.
    _typedExchangeRate = null;
    _touchSubmissionIntent();
    notifyListeners();
  }

  void updateTypedExchangeRate(double? value) {
    if (_isSubmitting) {
      return;
    }
    _typedExchangeRate = (value != null && value > 0) ? value : null;
    _touchSubmissionIntent();
    notifyListeners();
  }

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
        _adoptSellingPricesFrom(result.value.variants);
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
        _adoptSellingPricesFrom(result.value.variants);
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
    _syncSuggestions();
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  /// The draft line the last scan or catalog tap landed on, if it is still in
  /// the draft — the target of the arrow-key unit cycle and the function keys.
  PurchaseDraftLine? get lastScannedDraftLine {
    final variantId = _lastScannedVariantId;
    if (variantId == null) {
      return null;
    }
    return _draft.where((line) => line.variant.id == variantId).firstOrNull;
  }

  /// The line the keyboard acts on: the one the buyer tapped to select, else
  /// the last scanned/added line. Mirrors the POS's `activeCartLine`.
  PurchaseDraftLine? get activeDraftLine {
    final selected = _selectedVariantId;
    if (selected != null) {
      final line = _draft.where((l) => l.variant.id == selected).firstOrNull;
      if (line != null) {
        return line;
      }
    }
    return lastScannedDraftLine;
  }

  int? _selectedVariantId;

  /// Which line the draft pane has highlighted. Kept here rather than in the
  /// pane's state so the function keys (which fire through the global scan
  /// listener, outside the focus tree) and the pane agree on one target.
  int? get selectedVariantId => _selectedVariantId;

  void selectLine(int? variantId) {
    if (_selectedVariantId == variantId) {
      return;
    }
    _selectedVariantId = variantId;
    notifyListeners();
  }

  PurchaseSearchFocusController get searchFocusController =>
      _searchFocusController;
  PurchaseSearchResetController get searchResetController =>
      _searchResetController;

  /// Asks the catalog search field to take focus back. Called at resting points
  /// only — never mid quantity-edit, which would yank the caret out of the
  /// number the buyer is typing.
  void requestSearchFocus() => _searchFocusController.requestFocus();

  void requestSearchReset() => _searchResetController.requestReset();

  PurchaseScanStatus get scanStatus => _scanStatus;
  String? get lastScannedBarcode => _lastScannedBarcode;
  String? get lastScannedProductName => _lastScannedProductName;

  /// Publishes where a scan got to, for the catalog pane's status line.
  void reportScanStatus(
    PurchaseScanStatus status, {
    String? barcode,
    String? productName,
  }) {
    _scanStatus = status;
    if (barcode != null) {
      _lastScannedBarcode = barcode;
    }
    if (productName != null) {
      _lastScannedProductName = productName;
    }
    notifyListeners();
  }

  void clearScanStatus() {
    if (_scanStatus == PurchaseScanStatus.idle) {
      return;
    }
    _scanStatus = PurchaseScanStatus.idle;
    notifyListeners();
  }

  /// Lifts a line out of the draft, returning it and where it sat so the caller
  /// can offer an Undo. Returns null when the line is gone or a submit is in
  /// flight. The deliberate counterpart to [decrementVariant], which only ever
  /// removes a line by stepping its quantity to zero.
  RemovedPurchaseDraftLine? removeLine(
    int variantId, {
    String source = 'purchase_draft_delete_line',
  }) {
    if (_isSubmitting) {
      return null;
    }
    final index = _draft.indexWhere((line) => line.variant.id == variantId);
    if (index == -1) {
      return null;
    }
    final line = _draft.removeAt(index);
    if (_selectedVariantId == variantId) {
      _selectedVariantId = null;
    }
    if (_lastScannedVariantId == variantId) {
      _lastScannedVariantId = null;
    }
    _trackDraftLineDeleted(line, reason: 'delete_line', source: source);
    _syncSuggestions();
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
    return RemovedPurchaseDraftLine(line, index);
  }

  /// Puts a removed line back where it was (the Undo action on the snackbar).
  void restoreLine(RemovedPurchaseDraftLine removed) {
    if (_isSubmitting) {
      return;
    }
    if (_draft.any((line) => line.variant.id == removed.line.variant.id)) {
      return;
    }
    final index = removed.index.clamp(0, _draft.length);
    _draft.insert(index, removed.line);
    _syncSuggestions();
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
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
    _lastCostByVariantId[variant.id] = factor > 0
        ? unitCost / factor
        : unitCost;
    _draft[index] = _draft[index].copyWith(unitCost: unitCost);
    _touchSubmissionIntent();
    notifyListeners();
    unawaited(refreshDiscountPreview());
  }

  /// Sets a line's unit cost from a typed LINE TOTAL, dividing by the quantity.
  /// Suppliers write invoices as totals ("12 cartons — 1,200"), so this lets the
  /// buyer key the number that is actually on the paper instead of doing the
  /// division — the step where a per-carton cost most often becomes a per-piece
  /// one and poisons the product's cost history.
  void setLineCostFromTotal(ProductVariant variant, double total) {
    if (_isSubmitting || total < 0) {
      return;
    }
    final index = _draft.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }
    final quantity = _draft[index].quantity;
    if (quantity <= 0) {
      return;
    }
    updateLineCost(variant, total / quantity);
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

  // --- Suggestions ---------------------------------------------------------
  //
  // Everything below is additive: it adds lines the buyer could have added by
  // hand, in the quantity they usually use, and it never touches a line they
  // have already edited. A suggestion the buyer ignores costs them nothing.

  /// Tell the suggestion strip what the draft looks like now. Called at every
  /// point the answer could change; the controller debounces and caches, so
  /// calling it freely is the cheap option.
  void _syncSuggestions() {
    suggestions.update(
      supplierId: _selectedSupplier?.id,
      variantIds: [for (final line in _draft) line.variant.id],
    );
  }

  /// Add a suggested product to the draft, in its habitual unit and quantity.
  ///
  /// Behaves exactly like tapping the product in the catalog, plus the quantity
  /// and the unit the shop usually buys it in. Returns false when the product
  /// could not be resolved, which leaves the draft untouched.
  Future<bool> acceptSuggestion(
    PurchaseSuggestion suggestion, {
    String source = 'purchase_suggestion_chip',
  }) async {
    if (_isSubmitting) {
      return false;
    }
    final variant = await _resolveVariant(suggestion.variantId);
    if (variant == null || _isSubmitting) {
      return false;
    }
    await _addSuggestedVariant(variant, suggestion, source: source);
    _trackSuggestionAccepted(suggestion, source: source);
    return true;
  }

  /// Fill the draft with this supplier's recurring order in one action.
  ///
  /// Returns the variant ids actually added so the caller can offer a single
  /// Undo — a bulk add the buyer cannot take back in one gesture would be an
  /// imposition, which is the one thing this feature must never be.
  Future<List<int>> fillUsualBasket({
    String source = 'purchase_suggestion_usual_basket',
  }) async {
    if (_isSubmitting) {
      return const [];
    }
    final items = suggestions.usualBasket.items;
    if (items.isEmpty) {
      return const [];
    }
    final onDraft = {for (final line in _draft) line.variant.id};
    final wanted = [
      for (final item in items)
        if (!onDraft.contains(item.variantId)) item,
    ];
    if (wanted.isEmpty) {
      return const [];
    }
    // One batched read for the whole basket rather than a request per line.
    final resolved = await _resolveVariants(
      wanted.map((item) => item.variantId),
    );
    final added = <int>[];
    for (final item in wanted) {
      final variant = resolved[item.variantId];
      if (variant == null || _isSubmitting) {
        continue;
      }
      await _addSuggestedVariant(variant, item, source: source);
      added.add(item.variantId);
    }
    if (added.isNotEmpty) {
      _trackUsualBasketFilled(added.length, source: source);
    }
    return added;
  }

  /// Set a draft line to the quantity this shop usually buys — the line tile's
  /// "usual 12" chip and the F6 key.
  void applySuggestedQuantity(
    PurchaseDraftLine line,
    PurchaseSuggestion suggestion, {
    String source = 'purchase_suggestion_quantity_hint',
  }) {
    final quantity = suggestion.suggestedQuantity;
    if (quantity == null || quantity <= 0 || _isSubmitting) {
      return;
    }
    final unit = _purchaseUnitByCode(line.variant, suggestion.unitCode);
    if ((unit?.code ?? '') != line.unitCode) {
      // The habitual quantity counts cartons, not pieces: switch the line's
      // unit first or the number would mean something else entirely.
      updateLineUnit(
        line.variant,
        unitCode: unit?.code ?? '',
        unitLabel: unit?.label ?? '',
        unitFactor: unit?.factorToBase ?? 1,
        allowsFractional: _unitAllowsFractional(line.variant, unit),
      );
    }
    setLineQuantity(line.variant, quantity, source: source);
    _trackSuggestionAccepted(suggestion, source: source);
  }

  /// The quantity hint for a draft line, or null when the shop's history does
  /// not support one — or when the buyer is already on that quantity.
  PurchaseSuggestion? quantityHintFor(PurchaseDraftLine line) {
    final hint = suggestions.quantityHintFor(line.variant.id);
    if (hint == null) {
      return null;
    }
    final unit = _purchaseUnitByCode(line.variant, hint.unitCode);
    if ((unit?.code ?? '') == line.unitCode &&
        line.quantity == hint.suggestedQuantity) {
      return null;
    }
    return hint;
  }

  Future<void> _addSuggestedVariant(
    ProductVariant variant,
    PurchaseSuggestion suggestion, {
    required String source,
  }) async {
    // Seed the cost cache from the suggestion so the add does not have to go
    // back to the server for a number it was already handed. Both maps take it:
    // they carry the same per-base-unit definition the last-cost endpoint does.
    final baseCost = suggestion.baseUnitCost;
    if (baseCost != null && baseCost > 0) {
      _lastCostByVariantId[variant.id] = baseCost;
      _previousBaseCostByVariantId[variant.id] = baseCost;
    }
    final unit = _purchaseUnitByCode(variant, suggestion.unitCode);
    // Only carry the suggested cost when the suggested unit actually exists on
    // this product; otherwise the line lands in a different unit and the cost
    // would be per the wrong pack. The base-cost path below then rescales it.
    final unitMatches = (unit?.code ?? '') == suggestion.unitCode;
    await addVariant(
      variant,
      quantity: suggestion.suggestedQuantity ?? 1,
      unit: unit,
      unitCost: unitMatches ? suggestion.unitCost : null,
      source: source,
    );
  }

  /// A purchasable unit of [variant] by code; null for the base unit or for a
  /// code the product no longer carries.
  ProductUnit? _purchaseUnitByCode(ProductVariant variant, String unitCode) {
    if (unitCode.isEmpty) {
      return null;
    }
    final product = variant.productDetail;
    if (product == null) {
      return null;
    }
    for (final unit in product.purchasableUnits) {
      if (unit.code == unitCode) {
        return unit;
      }
    }
    return null;
  }

  Future<ProductVariant?> _resolveVariant(int variantId) async {
    final resolved = await _resolveVariants([variantId]);
    return resolved[variantId];
  }

  /// Variants by id, preferring what the catalog page already holds and
  /// fetching only the remainder — a suggestion for a product that is not on
  /// the current page (the common case, since the strip's whole job is to name
  /// products the buyer has not searched for) must still be one tap.
  Future<Map<int, ProductVariant>> _resolveVariants(
    Iterable<int> variantIds,
  ) async {
    final wanted = {...variantIds};
    final resolved = <int, ProductVariant>{};
    for (final variant in _variants) {
      if (wanted.remove(variant.id)) {
        resolved[variant.id] = variant;
      }
    }
    for (final line in _draft) {
      if (wanted.remove(line.variant.id)) {
        resolved[line.variant.id] = line.variant;
      }
    }
    if (wanted.isEmpty) {
      return resolved;
    }
    final fetched = await _catalogRepository.loadVariantsByIds(wanted);
    for (final variant in fetched) {
      resolved[variant.id] = variant;
    }
    return resolved;
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
    // A new order starts with a clean strip: a dismissal was "not now", and
    // "now" has moved on.
    suggestions.reset();
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
    _syncSuggestions();
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

  /// Re-previews the draft once it has been idle for [discountPreviewDebounce].
  ///
  /// Calls that arrive while a preview is pending fold into it; the returned
  /// future completes when the preview that finally runs has settled, so a
  /// caller can still await the result. An empty draft answers at once.
  Future<void> refreshDiscountPreview() {
    if (_draft.isEmpty || _selectedSupplier == null || _disposed) {
      _discountPreviewDebounceTimer?.cancel();
      _discountPreviewDebounceTimer = null;
      final settled = _discountPreviewSettled;
      _discountPreviewSettled = null;
      settled?.complete();
      return _refreshDiscountPreviewNow();
    }
    final settled = _discountPreviewSettled ??= Completer<void>();
    _discountPreviewDebounceTimer?.cancel();
    _discountPreviewDebounceTimer = Timer(discountPreviewDebounce, () {
      _discountPreviewDebounceTimer = null;
      _discountPreviewSettled = null;
      _refreshDiscountPreviewNow().whenComplete(settled.complete);
    });
    return settled.future;
  }

  Future<void> _refreshDiscountPreviewNow() async {
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

  /// Cost warnings the backend raised on the last submit attempt, if any.
  ///
  /// Non-empty means the draft was refused because a cost reads as a typo — the
  /// screen shows these and, when they are not blocking, offers to submit again
  /// with [acknowledgeCostWarnings].
  List<PurchaseCostWarning> get costWarnings =>
      List.unmodifiable(_costWarnings);
  List<PurchaseCostWarning> _costWarnings = const [];

  void clearCostWarnings() {
    if (_costWarnings.isEmpty) {
      return;
    }
    _costWarnings = const [];
    notifyListeners();
  }

  Future<Result<PurchaseSubmission>> submitDraft({
    bool acknowledgeCostWarnings = false,
  }) async {
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
      warehouseId: _selectedWarehouse?.id,
      supplierInvoiceNumber: _supplierInvoiceNumber,
      supplierInvoiceDate: supplierInvoiceDate,
      currencyCode: _currencyCode,
      exchangeRate: _typedExchangeRate,
      landedCostEntries: _landedCostEntries,
      landedCostAllocationMethod: _landedCostAllocationMethod,
      discountCode: _discountCode,
      extraDiscountAmount: _extraDiscount,
      idempotencyKey: _submitIdempotencyKey,
      acknowledgeCostWarnings: acknowledgeCostWarnings,
    );
    switch (result) {
      case Ok<PurchaseSubmission>():
        _costWarnings = const [];
        _trackDraftSubmitted(result.value, supplier: supplier);
        _draft.clear();
        _selectedSupplier = null;
        _supplierInvoiceNumber = '';
        _supplierInvoiceDateInput = '';
        _currencyCode = '';
        _typedExchangeRate = null;
        _discountCode = '';
        _resetLandedCosts();
        _clearDiscountPreview();
        _touchSubmissionIntent();
      case Error<PurchaseSubmission>(exception: final exception):
        _costWarnings = purchaseCostWarningsFromException(exception);
        _trackDraftSubmitFailed(supplier, exception);
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
    _editingOrderStatus = order.status;
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
    _syncSuggestions();
    notifyListeners();
    unawaited(refreshDiscountPreview());
    // A reopened order's lines carry the costs it was saved with, not what the
    // shop paid the time before — fetch that so each line can still say whether
    // its cost has moved.
    unawaited(loadPreviousCostsForDraft());
  }

  /// Persists edits to the reopened draft order without committing it — the
  /// order stays a draft, ready to be submitted later from its details screen.
  /// Returns an error result (and is a no-op) unless [isEditing].
  Future<Result<PurchaseOrder>> saveDraft({
    bool acknowledgeCostWarnings = false,
  }) async {
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
      acknowledgeCostWarnings: acknowledgeCostWarnings,
    );
    switch (result) {
      case Ok<PurchaseOrder>():
        _costWarnings = const [];
        _trackDraftSaved(result.value, supplier: supplier);
      case Error<PurchaseOrder>(exception: final exception):
        // Without this the edit screen had nowhere to read the refusal from and
        // no way to confirm it: a cost the guard flags made saving an edited
        // order impossible rather than merely gated. On 4–5 September one shop
        // hit that wall 41 times across two orders.
        _costWarnings = purchaseCostWarningsFromException(exception);
        _trackDraftSubmitFailed(supplier, exception);
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
    final products = await _productsForOrderLines(productIds);

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

  /// The products an order's lines refer to, keyed by id.
  ///
  /// One catalog request for the whole order: opening a long order used to
  /// fire a product-detail fetch per line in parallel, and the field showed
  /// bursts of up to 59 such fetches queuing behind each other at ~3 s each.
  /// If the bulk request itself fails, the per-product path is kept as a
  /// fallback so a transient error still resolves as many lines as it can
  /// instead of reporting every line as unresolved.
  Future<Map<int, Product>> _productsForOrderLines(List<int> productIds) async {
    final products = <int, Product>{};
    if (productIds.isEmpty) {
      return products;
    }
    switch (await _catalogRepository.loadProductsByIds(productIds)) {
      case Ok<List<Product>>(:final value):
        for (final product in value) {
          products[product.id] = product;
        }
        return products;
      case Error<List<Product>>():
        final results = await Future.wait(
          productIds.map(_catalogRepository.loadProduct),
        );
        for (var i = 0; i < productIds.length; i += 1) {
          if (results[i] case Ok<Product>(:final value)) {
            products[productIds[i]] = value;
          }
        }
        return products;
    }
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
    if (cost > 0) {
      _previousBaseCostByVariantId[variantId] = cost;
    }
    return cost;
  }

  /// What the shop last paid for this variant, per base unit, if it is already
  /// known — never a fetch, so a line tile can ask on every rebuild. Null when
  /// the product has never been bought (or the read has not landed yet).
  double? previousBaseCostFor(int variantId) =>
      _previousBaseCostByVariantId[variantId];

  /// Warms [previousBaseCostFor] for every line in the draft. Called once when
  /// the pricing UI needs it — a draft restored from storage, or an order
  /// reopened for editing, carries lines whose costs were never fetched.
  Future<void> loadPreviousCostsForDraft() async {
    final pending = [
      for (final line in _draft)
        if (!_previousBaseCostByVariantId.containsKey(line.variant.id))
          line.variant,
    ];
    if (pending.isEmpty) {
      return;
    }
    for (final variant in pending) {
      final result = await _purchaseRepository.loadLastProductCost(
        variant.productId,
        variantId: variant.id,
      );
      if (_disposed) {
        return;
      }
      final cost = switch (result) {
        Ok<double?>(:final value) => value ?? 0,
        Error<double?>() => 0.0,
      };
      if (cost > 0) {
        _previousBaseCostByVariantId[variant.id] = cost;
      }
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Per-variant purchase-cost history (lowest / highest / average / last, all
  /// per base unit) for the pricing sheet — the context that turns "type a new
  /// price" into "decide a price", and the same figures the product-details
  /// screen shows. Empty on failure: cost history is background for a decision,
  /// never a reason to refuse to make it.
  Future<List<VariantCostSummary>> loadProductCostSummary(int productId) async {
    // Opening the pricing sheet is the one moment the previous cost is worth a
    // round trip on its own: it is a headline figure there, and the line may
    // have been added with a cost that skipped the usual lookup.
    unawaited(loadPreviousCostsForDraft());
    final result = await _purchaseRepository.loadProductCostSummary(productId);
    return switch (result) {
      Ok<List<VariantCostSummary>>(:final value) => value,
      Error<List<VariantCostSummary>>() => const <VariantCostSummary>[],
    };
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

  /// Writes new selling prices for a product — per variant (the base-unit
  /// price) and per pack unit — from the pricing sheet. Only the entries passed
  /// are changed; a [pricesByUnitCode] entry with a null value hands that pack
  /// back to its derived `variant price x factor`. Returns success.
  Future<bool> repriceProduct(
    int productId, {
    Map<int, double> pricesByVariant = const {},
    Map<String, double?> pricesByUnitCode = const {},
  }) async {
    if (pricesByVariant.isEmpty && pricesByUnitCode.isEmpty) {
      return true;
    }
    final result = await _catalogRepository.setVariantPrices(
      productId: productId,
      pricesByVariant: pricesByVariant,
      pricesByUnitCode: pricesByUnitCode,
    );
    if (result is! Ok<Product>) {
      return false;
    }
    // The draft shows each line's current selling price and the pack prices
    // beside it; what was just written IS that price now, so the draft adopts
    // the whole updated product rather than waiting for a catalog reload. Both
    // adoptions notify ONCE, together — a reprice is one change to the screen,
    // and two notifications would repaint the cart twice for it.
    _applySellingPrices(pricesByVariant, notify: false);
    _adoptProductDetail(result.value, notify: false);
    if (!_disposed) {
      notifyListeners();
    }
    return true;
  }

  /// Re-embeds a freshly saved product onto every draft line that belongs to
  /// it, so the pack prices the pricing sheet just wrote are the ones the line
  /// reads back. Without this the sheet would reopen showing the old pack
  /// prices until the catalog happened to reload.
  void _adoptProductDetail(Product product, {bool notify = true}) {
    if (_disposed) {
      return;
    }
    var changed = false;
    for (var index = 0; index < _draft.length; index += 1) {
      final line = _draft[index];
      if (line.variant.productId != product.id) {
        continue;
      }
      _draft[index] = line.copyWith(
        variant: line.variant.copyWith(productDetail: product),
      );
      changed = true;
    }
    if (changed && notify) {
      notifyListeners();
    }
  }

  /// Refreshes the selling price shown on every draft line, in as few requests
  /// as the server allows (one for a normal cart). Only worth doing for a draft
  /// restored from local storage: a line added from the catalog, a scan, or a
  /// reopened order carries a price that was current when it was added, whereas
  /// a restored draft's prices are as old as the draft itself.
  Future<void> refreshDraftSellingPrices() async {
    if (_draft.isEmpty || _isRefreshingSellingPrices || _disposed) {
      return;
    }
    _isRefreshingSellingPrices = true;
    final requestedIds = {for (final line in _draft) line.variant.id};
    try {
      final variants = await _catalogRepository.loadVariantsByIds(requestedIds);
      _adoptSellingPricesFrom(variants, notify: true);
    } finally {
      _isRefreshingSellingPrices = false;
    }
  }

  /// Adopts the selling prices carried by [variants] onto any draft line for
  /// the same variant. Free freshness: the catalog pages the pane loads anyway
  /// carry current prices, so browsing heals a stale cart line.
  void _adoptSellingPricesFrom(
    Iterable<ProductVariant> variants, {
    bool notify = false,
  }) {
    if (_draft.isEmpty) {
      return;
    }
    final draftVariantIds = {for (final line in _draft) line.variant.id};
    final prices = <int, double>{
      for (final variant in variants)
        if (draftVariantIds.contains(variant.id)) variant.id: variant.unitPrice,
    };
    _applySellingPrices(prices, notify: notify);
  }

  /// Writes [pricesByVariantId] onto the matching draft lines. Untouched when
  /// nothing actually changed, so a catalog reload of an unchanged price costs
  /// no rebuild.
  void _applySellingPrices(
    Map<int, double> pricesByVariantId, {
    bool notify = true,
  }) {
    if (pricesByVariantId.isEmpty || _disposed) {
      return;
    }
    var changed = false;
    for (var index = 0; index < _draft.length; index += 1) {
      final line = _draft[index];
      final price = pricesByVariantId[line.variant.id];
      if (price == null || price == line.variant.unitPrice) {
        continue;
      }
      _draft[index] = line.copyWith(
        variant: line.variant.copyWith(unitPrice: price),
      );
      changed = true;
    }
    if (!changed) {
      return;
    }
    // Display-only: the selling price never feeds the order's totals, so this
    // deliberately leaves the submission intent (and its idempotency key)
    // alone and only re-persists what the draft already holds.
    _schedulePersist();
    if (notify) {
      notifyListeners();
    }
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
    _disposed = true;
    _persistDebounce?.cancel();
    _discountPreviewDebounceTimer?.cancel();
    _discountPreviewSettled?.complete();
    _discountPreviewSettled = null;
    suggestions.removeListener(notifyListeners);
    suggestions.dispose();
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
      _syncSuggestions();
      notifyListeners();
      // The restored lines carry the selling price each product had when it
      // was added, which may be days old — refresh the whole cart in one go.
      unawaited(refreshDraftSellingPrices());
      // A restored line's cost was never fetched in this session, so nothing
      // knows what the shop paid last time — without this the "cost moved"
      // reading is simply absent on every line of a resumed draft.
      unawaited(loadPreviousCostsForDraft());
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

  /// Which suggestions the buyer actually took, and for which reason.
  ///
  /// This is the metric the whole feature is judged on: acceptance by reason,
  /// paired with whether the line was still on the order at submit. Emitted on
  /// the accept only — never on render, so a strip that rebuilds on every
  /// keystroke cannot turn into an event storm.
  void _trackSuggestionAccepted(
    PurchaseSuggestion suggestion, {
    required String source,
  }) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'purchasing.draft.suggestion.accepted',
          entityType: 'purchase_suggestion',
          entityId: '${suggestion.variantId}',
          attributes: {
            'source': source,
            'reason': suggestion.reason.name,
            'supplier_id': _selectedSupplier?.id,
            'supplier_name': _selectedSupplier?.name,
            'variant_id': suggestion.variantId,
            'product_id': suggestion.productId,
            'product_name': suggestion.productName,
            'had_quantity': suggestion.hasQuantity,
            'draft_line_count': _draft.length,
          },
          metrics: {
            'score': suggestion.score,
            'evidence_orders': suggestion.orderCount,
            'suggested_quantity': suggestion.suggestedQuantity ?? 0,
            'draft_line_count': _draft.length,
          },
        ),
      ),
    );
  }

  void _trackUsualBasketFilled(int lineCount, {required String source}) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'purchasing.draft.suggestion.basket_filled',
          entityType: 'supplier',
          entityId: '${_selectedSupplier?.id}',
          attributes: {
            'source': source,
            'supplier_id': _selectedSupplier?.id,
            'supplier_name': _selectedSupplier?.name,
            'draft_line_count': _draft.length,
          },
          metrics: {
            'lines_added': lineCount,
            'draft_line_count': _draft.length,
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

  /// [error] is what the save actually failed with.
  ///
  /// It used to be omitted, and the consequence showed up in the field export:
  /// 49 `submit_failed` events carrying no status and no reason, against a
  /// backend that had returned a specific 400 every time. An error event that
  /// cannot say why is barely an event.
  void _trackDraftSubmitFailed(SupplierContact supplier, [Object? error]) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    final statusCode = apiStatusCode(error);
    final detail = apiErrorDetail(error);
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
            'status_code': ?statusCode,
            'error_code': ?apiErrorCode(error),
            // The reason, trimmed: enough to group failures in an export
            // without shipping a paragraph per event.
            if (detail.isNotEmpty)
              'reason': detail.length > 200 ? detail.substring(0, 200) : detail,
            'cost_warning_count': _costWarnings.length,
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
