import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/barcode_resolution.dart';
import '../../../data/models/cart_line.dart';
import '../../../data/models/modifier_group.dart';
import '../../../shared/barcode/scale_barcode.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/formatters.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/models/print_job.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_page.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/register_session_summary.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/register_session_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/api_error_detail.dart';
import '../../../data/services/order_document_service.dart';
import '../../../data/services/local_scoped_json_storage.dart';
import '../../../shared/unit_options.dart';
import '../../../core/analytics_burst_coalescer.dart';

part 'pos_cart_actions.dart';
part 'pos_catalog_actions.dart';
part 'pos_barcode_actions.dart';
part 'pos_checkout.dart';
part 'pos_register_session_actions.dart';
part 'pos_sale_session_actions.dart';
part 'pos_persistence.dart';

enum RegisterSessionGateStatus {
  loading,
  noOpenSession,
  openSessionAvailable,
  active,
}

enum BarcodeScanStatus { idle, resolving, found, notFound, error }

/// Lets the POS view model ask the catalog search field to reclaim keyboard
/// focus at natural resting points in the cashier's flow — a completed sale, a
/// finished line-quantity edit, a product added from the grid — so the next
/// item can be searched or scanned without a tap. It is a pure signal: the
/// search field itself decides whether taking focus is appropriate right now
/// (never while a sheet or dialog is up, never on the compact phone layout).
class PosSearchFocusController extends ChangeNotifier {
  void requestFocus() => notifyListeners();
}

/// Lets the POS view model tell the catalog search field to hard-reset: clear
/// its text AND cancel any in-flight debounce. Needed after a hardware scan —
/// the scanner's key burst lands in the (focused) search field and starts a
/// debounced search; even though [BarcodeScanListener] restores the field, that
/// pending debounce would otherwise fire ~350ms later and push the barcode back
/// into the field (and filter the grid to it). Firing this on every scan
/// cancels that debounce so the barcode never reappears. A pure signal, like
/// [PosSearchFocusController].
class PosSearchResetController extends ChangeNotifier {
  void requestReset() => notifyListeners();
}

enum PosProductSelectionStatus {
  added,
  chooseVariant,
  chooseModifiers,
  unavailable,
  error,
  weighVariant,
}

class PosProductSelectionResult {
  const PosProductSelectionResult._({
    required this.status,
    this.variants = const [],
    this.weighedVariant,
    this.modifierVariant,
  });

  const PosProductSelectionResult.added()
    : this._(status: PosProductSelectionStatus.added);

  const PosProductSelectionResult.chooseVariant(List<ProductVariant> variants)
    : this._(
        status: PosProductSelectionStatus.chooseVariant,
        variants: variants,
      );

  const PosProductSelectionResult.unavailable()
    : this._(status: PosProductSelectionStatus.unavailable);

  const PosProductSelectionResult.error()
    : this._(status: PosProductSelectionStatus.error);

  const PosProductSelectionResult.weighVariant(ProductVariant variant)
    : this._(
        status: PosProductSelectionStatus.weighVariant,
        variants: const [],
        weighedVariant: variant,
      );

  const PosProductSelectionResult.chooseModifiers(ProductVariant variant)
    : this._(
        status: PosProductSelectionStatus.chooseModifiers,
        modifierVariant: variant,
      );

  final PosProductSelectionStatus status;
  final List<ProductVariant> variants;
  final ProductVariant? weighedVariant;
  final ProductVariant? modifierVariant;
}

class PosSaleSessionSummary {
  const PosSaleSessionSummary({
    required this.id,
    required this.number,
    required this.lineCount,
    required this.itemCount,
    required this.subtotal,
    required this.total,
    required this.isActive,
    required this.customerName,
  });

  final int id;
  final int number;
  final int lineCount;
  final double itemCount;
  final double subtotal;
  final double total;
  final bool isActive;
  final String? customerName;

  bool get isEmpty => lineCount == 0;
}

class PosViewModel extends ChangeNotifier {
  PosViewModel(
    this._catalogRepository,
    this._registerSessionRepository,
    this._saleRepository,
    this._shopSettingsRepository,
    this._printingRepository, {
    AnalyticsEngine? analyticsEngine,
    ScopedJsonStorage sessionStorage = const SharedPreferencesScopedJsonStorage(
      'pointy.pos.sessions.v1',
    ),
    ScanFeedbackPlayer? scanFeedback,
    Duration checkoutPrintDeadline = const Duration(seconds: 20),
    this.cartQuantityIdleTimeout = const Duration(milliseconds: 700),
  }) : _analyticsEngine = analyticsEngine,
       _sessionStorage = sessionStorage,
       _scanFeedback = scanFeedback,
       _checkoutPrintDeadline = checkoutPrintDeadline;

  /// How long a +/- run may pause before it counts as finished.
  ///
  /// Auto-repeat fires roughly every 100ms and a deliberate second press is far
  /// slower than this, so the boundary lands where the cashier's intent
  /// changes rather than where the keyboard happened to repeat.
  final Duration cartQuantityIdleTimeout;

  /// Open +/- runs, one per cart line — see PosCartActions.
  late final BurstCoalescer<_CartQuantityRun> _cartQuantityRuns =
      BurstCoalescer<_CartQuantityRun>(
        idleTimeout: cartQuantityIdleTimeout,
        onSettled: _emitCartQuantityRun,
      );

  final CatalogRepository _catalogRepository;
  final RegisterSessionRepository _registerSessionRepository;
  final SaleRepository _saleRepository;
  final ShopSettingsRepository _shopSettingsRepository;
  final PrintingRepository _printingRepository;
  final AnalyticsEngine? _analyticsEngine;
  final ScopedJsonStorage _sessionStorage;
  // Audible scan feedback (null = silent, e.g. unit tests).
  final ScanFeedbackPlayer? _scanFeedback;

  /// Hard ceiling on any single post-sale print step at checkout. The sale is
  /// already committed by the time we print, so a step that overruns this is
  /// abandoned as a failure rather than freezing the POS. It sits above the
  /// per-write transport timeout (`PrinterEndpoint.timeoutMs`, 5s default) so a
  /// transport usually surfaces its own failure first; this is the backstop for
  /// hangs a Dart timeout can't interrupt on its own (e.g. a wedged OS print
  /// spooler on the document/PDF path). Injectable so tests can drive the
  /// timeout without waiting real seconds.
  final Duration _checkoutPrintDeadline;

  // Drives the "return focus to catalog search" moments (see
  // PosSearchFocusController). Owned here so both view-model events (checkout,
  // new invoice, cart cleared) and the catalog/cart panes can fire it.
  final PosSearchFocusController _searchFocusController =
      PosSearchFocusController();
  // Fired after a barcode scan to cancel the search field's pending debounce so
  // the scanned code can't round-trip back into the field. See
  // [requestSearchReset].
  final PosSearchResetController _searchResetController =
      PosSearchResetController();

  // Local persistence of in-progress sale sessions (see pos_persistence.dart).
  String? _persistScope;
  bool _sessionsRestored = false;
  Timer? _persistDebounce;

  CatalogRepository get catalogRepository => _catalogRepository;

  /// Observed by the catalog search field so it can pull focus back at the
  /// cashier's resting points. See [requestSearchFocus].
  PosSearchFocusController get searchFocusController => _searchFocusController;

  /// Observed by the catalog search field so it can clear itself (and cancel any
  /// pending debounce) after a scan. See [requestSearchReset].
  PosSearchResetController get searchResetController => _searchResetController;

  /// Asks the catalog search field to reclaim keyboard focus so the cashier can
  /// immediately look up or scan the next item. Fired at natural resting points
  /// (a completed sale, a finished line-quantity edit, a grid/scanner add, a
  /// fresh or switched invoice) — never mid-edit, so it can't yank the caret out
  /// from under a quantity being typed. A no-op when nothing is listening.
  void requestSearchFocus() => _searchFocusController.requestFocus();

  /// Asks the catalog search field to clear its text and cancel any in-flight
  /// debounce. Fired after every hardware/keyboard barcode scan so the scanned
  /// code — which briefly lands in the focused search field as a key burst —
  /// can't be pushed back into the field by a debounce that was already queued.
  /// A no-op when nothing is listening.
  void requestSearchReset() => _searchResetController.requestReset();

  List<Product> _products = [];
  final List<_PosSaleSession> _saleSessions = [
    _PosSaleSession(id: 1, number: 1),
  ];
  int _activeSaleSessionId = 1;

  // Latched when a live preview reports the shop has NO active sale discount
  // rules, keyed to the exact discounts version the server pushes on every
  // response. While it still matches, previews are computed locally — no
  // request, so the preview cannot fail. Cleared the moment rules appear.
  String? _noActiveDiscountRulesVersion;
  int _nextSaleSessionId = 2;
  int _nextSaleSessionNumber = 2;
  ShopSettings? _checkoutSettings;
  Uint8List? _checkoutShopLogoBytes;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isLoadingRegisterSession = false;
  bool _isLoadingCheckoutSettings = false;
  bool _isStartingRegisterSession = false;
  bool _isClosingRegisterSession = false;
  bool _isCreatingCashMovement = false;
  bool _isCheckingOut = false;
  BarcodeScanStatus _barcodeScanStatus = BarcodeScanStatus.idle;
  bool _hasMoreProducts = true;
  int _nextProductPage = 1;
  String? _errorMessage;
  String? _lastScannedBarcode;
  String? _lastScannedProductName;
  // How the last scan's scale label was read, when it was one. Kept so the
  // cashier can be told the two things a sticker can go wrong about: that the
  // product could not take the measurement, and that the price it rang is not
  // quite the price printed on it.
  ScaleQuantity? _scaleQuantity;
  // The cart line the shortcuts (F2 cycle-unit / F4 delete / arrow cycle-unit)
  // act on: the last line a scan or catalog tap landed on, or the last line the
  // cashier tapped to select. A hardware scan never touches a line's quantity —
  // it only ever adds/increments its own product.
  String? _activeCartLineKey;
  bool _hasRegisterSessionError = false;

  /// The server's own words for the last register-session failure, when it gave
  /// any. Shown beside the generic message so a refusal is answerable rather
  /// than just repeatable.
  String _registerSessionErrorMessage = '';
  bool _hasCheckoutSettingsError = false;
  RegisterSession? _availableRegisterSession;
  RegisterSession? _activeRegisterSession;
  // Id of the most recently closed session, so the close flow can offer to
  // print its Z-Report after the active session has already been cleared.
  int? _lastClosedRegisterSessionId;
  int _catalogRequestVersion = 0;
  Future<void>? _catalogLoadFuture;
  ProductQuery? _catalogLoadFutureQuery;
  Future<void>? _checkoutSettingsLoadFuture;
  Future<void>? _registerSessionLoadFuture;
  ProductQuery _query = const ProductQuery(
    availability: ProductAvailabilityFilter.active,
    // Overselling is disabled by default, so start by hiding out-of-stock
    // products; this is reconciled against the real shop setting once the
    // checkout settings load.
    stock: ProductStockFilter.inStockOnly,
    // Cashiers browse "most bought" first so the fast-movers are one tap away.
    ordering: ProductOrdering.mostBought,
  );

  _PosSaleSession get _activeSaleSession {
    return _saleSessions.firstWhere(
      (session) => session.id == _activeSaleSessionId,
    );
  }

  List<CartLine> get _cart => _activeSaleSession.cart;

  Customer? get _selectedCustomer => _activeSaleSession.selectedCustomer;

  set _selectedCustomer(Customer? customer) {
    _activeSaleSession
      ..selectedCustomer = customer
      ..touch();
  }

  String get _couponCode => _activeSaleSession.couponCode;

  set _couponCode(String value) {
    _activeSaleSession
      ..couponCode = value
      ..touch();
  }

  SaleDiscountPreview? get _discountPreview {
    return _activeSaleSession.discountPreview;
  }

  set _discountPreview(SaleDiscountPreview? preview) {
    _activeSaleSession.discountPreview = preview;
  }

  bool get _isLoadingDiscountPreview {
    return _activeSaleSession.isLoadingDiscountPreview;
  }

  bool get _hasDiscountPreviewError {
    return _activeSaleSession.hasDiscountPreviewError;
  }

  set _hasDiscountPreviewError(bool value) {
    _activeSaleSession.hasDiscountPreviewError = value;
  }

  bool get _printInvoiceAfterPayment {
    return _activeSaleSession.printInvoiceAfterPayment;
  }

  set _printInvoiceAfterPayment(bool value) {
    _activeSaleSession
      ..printInvoiceAfterPayment = value
      ..touch();
  }

  bool get _shareInvoiceAfterPayment {
    return _activeSaleSession.shareInvoiceAfterPayment;
  }

  set _shareInvoiceAfterPayment(bool value) {
    _activeSaleSession
      ..shareInvoiceAfterPayment = value
      ..touch();
  }

  List<Product> get products => List.unmodifiable(_products);
  List<CartLine> get cart => List.unmodifiable(_cart);
  List<PosSaleSessionSummary> get saleSessions {
    return List.unmodifiable(
      _saleSessions.map(_saleSessionSummary).toList(growable: false),
    );
  }

  PosSaleSessionSummary get activeSaleSessionSummary {
    return _saleSessionSummary(_activeSaleSession);
  }

  int get openSaleSessionCount => _saleSessions.length;
  int get activeSaleSessionNumber => _activeSaleSession.number;
  bool get canStartNewSaleSession => !_isCheckingOut && _cart.isNotEmpty;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadingRegisterSession => _isLoadingRegisterSession;
  bool get isLoadingCheckoutSettings => _isLoadingCheckoutSettings;
  bool get isStartingRegisterSession => _isStartingRegisterSession;
  bool get isClosingRegisterSession => _isClosingRegisterSession;
  bool get isCreatingCashMovement => _isCreatingCashMovement;
  bool get isCheckingOut => _isCheckingOut;
  BarcodeScanStatus get barcodeScanStatus => _barcodeScanStatus;
  bool get isResolvingBarcode =>
      _barcodeScanStatus == BarcodeScanStatus.resolving;
  bool get printInvoiceAfterPayment => _printInvoiceAfterPayment;
  bool get shareInvoiceAfterPayment => _shareInvoiceAfterPayment;
  Customer? get selectedCustomer => _selectedCustomer;
  bool get hasMoreProducts => _hasMoreProducts;
  String? get errorMessage => _errorMessage;
  String get couponCode => _couponCode;
  SaleDiscountPreview? get discountPreview => _discountPreview;
  bool get isLoadingDiscountPreview => _isLoadingDiscountPreview;
  bool get hasDiscountPreviewError => _hasDiscountPreviewError;
  double get discountTotal => _discountPreview?.discountTotal ?? 0;
  List<AppliedDiscountInfo> get appliedDiscounts =>
      _discountPreview?.appliedDiscounts ?? const [];
  List<String> get unappliedCouponCodes =>
      _discountPreview?.unappliedCouponCodes ?? const [];
  String? get lastScannedBarcode => _lastScannedBarcode;
  String? get lastScannedProductName => _lastScannedProductName;

  /// The last scan's scale-label reading, or null if it was not one.
  ScaleQuantity? get lastScaleQuantity => _scaleQuantity;
  bool get hasRegisterSessionError => _hasRegisterSessionError;
  String get registerSessionErrorMessage => _registerSessionErrorMessage;
  bool get hasCheckoutSettingsError => _hasCheckoutSettingsError;
  RegisterSession? get availableRegisterSession => _availableRegisterSession;
  RegisterSession? get activeRegisterSession => _activeRegisterSession;
  int? get lastClosedRegisterSessionId => _lastClosedRegisterSessionId;
  ProductQuery get query => _query;
  bool get requireOpeningCash => _checkoutSettings?.requireOpeningCash ?? true;
  bool get allowOverselling => _checkoutSettings?.allowOverselling ?? false;

  /// When overselling is disabled the POS catalog hides out-of-stock products
  /// so cashiers can't see or sell them.
  ProductStockFilter get _catalogStockFilter => allowOverselling
      ? ProductStockFilter.all
      : ProductStockFilter.inStockOnly;
  bool get preventSellingAtLoss =>
      _checkoutSettings?.preventSellingAtLoss ?? true;

  /// Whether the POS should confirm before completing an over-stock sale.
  /// On by default; shops can silence the prompt from Settings.
  bool get warnLowStockBeforeSale =>
      _checkoutSettings?.warnLowStockBeforeSale ?? true;
  bool get shouldShowPrintInvoiceCheckbox =>
      _checkoutSettings != null && !_checkoutSettings!.autoPrintReceipts;
  bool get shouldShowShareInvoiceCheckbox => shouldShowPrintInvoiceCheckbox;
  bool get enableCashPayments => _checkoutSettings?.enableCashPayments ?? true;
  bool get enableCardPayments => _checkoutSettings?.enableCardPayments ?? true;
  bool get enableTransferPayments =>
      _checkoutSettings?.enableTransferPayments ?? true;
  bool get requireCardPaymentReceipt =>
      _checkoutSettings?.requireCardPaymentReceipt ?? false;
  bool get enableKitchenOperations =>
      _checkoutSettings?.enableKitchenOperations ?? false;

  /// Whether a credit (آجل) or quotation (عرض سعر) sale must name a customer.
  bool get requireCustomerForCredit =>
      _checkoutSettings?.requireCustomerForCredit ?? true;

  /// The due date an آجل sale rung up now would fall due on, under the agreed
  /// terms — the attached customer's if they carry their own, otherwise the
  /// shop's. Both come pre-resolved from the server, so no calendar arithmetic
  /// happens here and the till proposes exactly the date the reports will age
  /// against. Null when no terms are configured, which means an open tab.
  DateTime? get proposedCreditDueDate {
    final customerTerms = _selectedCustomer?.effectivePaymentTerms;
    if (customerTerms != null) {
      return customerTerms.dueDateForToday;
    }
    return _checkoutSettings?.defaultPaymentTerms?.dueDateForToday;
  }

  List<String> get trustedCardTerminalIds =>
      _checkoutSettings?.trustedCardTerminalIds ?? const [];

  double get subtotal => _cart.fold(0, (sum, line) => sum + line.subtotal);
  double get total => _discountPreview?.total ?? subtotal;
  RegisterSessionGateStatus get registerSessionGateStatus {
    if (_activeRegisterSession != null) {
      return RegisterSessionGateStatus.active;
    }
    if (_isLoadingRegisterSession || _isLoadingCheckoutSettings) {
      return RegisterSessionGateStatus.loading;
    }
    if (_availableRegisterSession != null) {
      return RegisterSessionGateStatus.openSessionAvailable;
    }
    return RegisterSessionGateStatus.noOpenSession;
  }

  bool _disposed = false;

  void _notifyChanged() {
    // Async tasks (e.g. discount-preview refresh after a restore) can resolve
    // after disposal; guard so we never notify a disposed notifier.
    if (_disposed) {
      return;
    }
    notifyListeners();
    _schedulePersist();
  }

  @override
  void dispose() {
    _disposed = true;
    // Emit any run still open rather than losing what the cashier just did.
    _cartQuantityRuns.dispose();
    _persistDebounce?.cancel();
    _searchFocusController.dispose();
    _searchResetController.dispose();
    super.dispose();
  }

  Future<void> loadCheckoutSettings() {
    final inFlight = _checkoutSettingsLoadFuture;
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<void> future;
    future = _loadCheckoutSettings().whenComplete(() {
      if (identical(_checkoutSettingsLoadFuture, future)) {
        _checkoutSettingsLoadFuture = null;
      }
    });
    _checkoutSettingsLoadFuture = future;
    return future;
  }

  Future<void> _loadCheckoutSettings() async {
    _isLoadingCheckoutSettings = true;
    _hasCheckoutSettingsError = false;
    _notifyChanged();

    final result = await _shopSettingsRepository.loadSettings();
    switch (result) {
      case Ok<ShopSettings>():
        _checkoutSettings = result.value;
        // Make every on-screen money display use the shop's currency symbol.
        configureCurrencySymbol(
          result.value.currencySymbol,
          code: result.value.currencyCode,
        );
        _checkoutShopLogoBytes = await _loadShopLogoBytes(result.value);
        if (result.value.autoPrintReceipts) {
          _clearManualInvoiceActionsForSaleSessions();
        }
      case Error<ShopSettings>():
        _checkoutSettings = null;
        _checkoutShopLogoBytes = null;
        _clearManualInvoiceActionsForSaleSessions();
        _hasCheckoutSettingsError = true;
    }

    _isLoadingCheckoutSettings = false;
    _notifyChanged();

    // The overselling setting decides whether out-of-stock products are hidden
    // from the catalog; reconcile the active query now that it is known.
    await syncCatalogStockVisibility();
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final result = await _shopSettingsRepository.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }

  void updatePrintInvoiceAfterPayment(bool value) {
    if (!shouldShowPrintInvoiceCheckbox ||
        _isCheckingOut ||
        value == _printInvoiceAfterPayment) {
      return;
    }
    _printInvoiceAfterPayment = value;
    _notifyChanged();
  }

  void updateShareInvoiceAfterPayment(bool value) {
    if (!shouldShowShareInvoiceCheckbox ||
        _isCheckingOut ||
        value == _shareInvoiceAfterPayment) {
      return;
    }
    _shareInvoiceAfterPayment = value;
    _notifyChanged();
  }

  Future<OrderDocumentActionStatus> sharePaidInvoice(SaleOrder order) {
    return _printingRepository.shareSaleInvoice(
      order: order,
      shopSettings: _checkoutSettings,
      shopLogoBytes: _checkoutShopLogoBytes,
    );
  }

  void selectCustomer(Customer? customer) {
    if (_isCheckingOut || customer == _selectedCustomer) {
      return;
    }
    _selectedCustomer = customer;
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  void updateCouponCode(String value) {
    if (_isCheckingOut || value == _couponCode) {
      return;
    }
    _couponCode = value;
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  PosSaleSessionSummary _saleSessionSummary(_PosSaleSession session) {
    final subtotal = _saleSessionSubtotal(session);
    return PosSaleSessionSummary(
      id: session.id,
      number: session.number,
      lineCount: session.cart.length,
      itemCount: session.cart.fold(0.0, (sum, line) => sum + line.quantity),
      subtotal: subtotal,
      total: session.discountPreview?.total ?? subtotal,
      isActive: session.id == _activeSaleSessionId,
      customerName: session.selectedCustomer?.fullName,
    );
  }

  double _saleSessionSubtotal(_PosSaleSession session) {
    return session.cart.fold(0, (sum, line) => sum + line.subtotal);
  }

  void _clearManualInvoiceActionsForSaleSessions() {
    for (final session in _saleSessions) {
      if (session.printInvoiceAfterPayment ||
          session.shareInvoiceAfterPayment) {
        session
          ..printInvoiceAfterPayment = false
          ..shareInvoiceAfterPayment = false
          ..touch();
      }
    }
  }
}

class _PosSaleSession {
  _PosSaleSession({required this.id, required this.number})
    : updatedAt = DateTime.now();

  final int id;
  final int number;
  DateTime updatedAt;
  final List<CartLine> cart = [];
  Customer? selectedCustomer;
  String couponCode = '';
  final Map<String, _PosCheckoutAttempt> _checkoutAttemptsBySignature = {};
  SaleDiscountPreview? discountPreview;
  bool isLoadingDiscountPreview = false;
  bool hasDiscountPreviewError = false;
  bool printInvoiceAfterPayment = false;
  bool shareInvoiceAfterPayment = false;
  int discountPreviewRequestVersion = 0;

  bool get isEmpty => cart.isEmpty;

  void touch() {
    updatedAt = DateTime.now();
    // The cart changed, so whatever was minted for the previous contents is no
    // longer this sale. A completed checkout drops the whole session, so the
    // cashier ringing the same basket twice in a row still gets a fresh key.
    _checkoutAttemptsBySignature.clear();
  }

  /// The idempotency key — and the exact invoice-print routing — to send for
  /// [draft]. Memoized per commercial signature so every retry of the same sale
  /// reaches the backend as a byte-identical request and replays instead of
  /// booking a second sale.
  _PosCheckoutAttempt checkoutAttemptFor(SaleCheckoutDraft draft) {
    return _checkoutAttemptsBySignature.putIfAbsent(
      _checkoutSignature(draft),
      () => _PosCheckoutAttempt(
        idempotencyKey: _newCheckoutIdempotencyKey(),
        invoicePrinterConfig: draft.invoicePrinterConfig,
      ),
    );
  }

  List<Object?> checkoutAttemptsToJson() {
    return [
      for (final entry in _checkoutAttemptsBySignature.entries)
        entry.value.toJson(entry.key),
    ];
  }

  void restoreCheckoutAttempts(Object? json) {
    if (json is! List) {
      return;
    }
    for (final item in json) {
      if (item is! Map) {
        continue;
      }
      final map = item.cast<String, Object?>();
      final signature = map['signature'];
      final key = map['key'];
      if (signature is! String || key is! String || key.isEmpty) {
        continue;
      }
      final printerJson = map['printer'];
      _checkoutAttemptsBySignature[signature] = _PosCheckoutAttempt(
        idempotencyKey: key,
        invoicePrinterConfig: printerJson is Map
            ? PrinterConfig.fromJson(printerJson.cast<String, Object?>())
            : null,
      );
    }
  }
}

/// One checkout request the cashier has already sent (or is about to send) for
/// the current cart: the key that makes it idempotent, plus the print routing
/// that was in the body, so a retry can reproduce the same body.
class _PosCheckoutAttempt {
  const _PosCheckoutAttempt({
    required this.idempotencyKey,
    required this.invoicePrinterConfig,
  });

  final String idempotencyKey;
  final PrinterConfig? invoicePrinterConfig;

  Map<String, Object?> toJson(String signature) {
    return {
      'signature': signature,
      'key': idempotencyKey,
      'printer': invoicePrinterConfig?.toJson(),
    };
  }
}

String _newCheckoutIdempotencyKey() {
  return 'checkout:${generateAnalyticsEventId()}';
}

/// The sale's commercial identity — the lines, payments, customer, coupon and
/// sale type the backend actually records.
///
/// `print_invoice` and `receipt_delivery` are deliberately left out. Which
/// printer the receipt goes to — and whether this till or an agent prints it —
/// does not make it a different sale, and while `print_invoice` was part of the
/// signature a printer config that resolved differently between two attempts
/// (the shop settings failing to reload during the very outage that made the
/// first attempt time out, clearing the manual print toggle) rotated the
/// idempotency key and booked the sale twice. `receipt_delivery` is derived
/// from the same settings and printer, so it can flip for exactly the same
/// reason and must be excluded for exactly the same reason.
String _checkoutSignature(SaleCheckoutDraft draft) {
  final body = draft.toJson()
    ..remove('print_invoice')
    ..remove('receipt_delivery');
  return jsonEncode(body);
}
