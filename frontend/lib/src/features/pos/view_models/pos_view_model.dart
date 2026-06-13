import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/cart_line.dart';
import '../../../shared/barcode/scale_barcode.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/print_job.dart';
import '../../../data/models/printer_config.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_page.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/register_session_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';

part 'pos_cart_actions.dart';
part 'pos_catalog_actions.dart';
part 'pos_barcode_actions.dart';
part 'pos_checkout.dart';
part 'pos_register_session_actions.dart';
part 'pos_sale_session_actions.dart';

enum RegisterSessionGateStatus {
  loading,
  noOpenSession,
  openSessionAvailable,
  active,
}

enum BarcodeScanStatus { idle, resolving, found, notFound, error }

enum PosProductSelectionStatus { added, chooseVariant, unavailable, error, weighVariant }

class PosProductSelectionResult {
  const PosProductSelectionResult._({
    required this.status,
    this.variants = const [],
    this.weighedVariant,
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

  final PosProductSelectionStatus status;
  final List<ProductVariant> variants;
  final ProductVariant? weighedVariant;
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
  }) : _analyticsEngine = analyticsEngine;

  final CatalogRepository _catalogRepository;
  final RegisterSessionRepository _registerSessionRepository;
  final SaleRepository _saleRepository;
  final ShopSettingsRepository _shopSettingsRepository;
  final PrintingRepository _printingRepository;
  final AnalyticsEngine? _analyticsEngine;

  CatalogRepository get catalogRepository => _catalogRepository;

  List<Product> _products = [];
  final List<_PosSaleSession> _saleSessions = [
    _PosSaleSession(id: 1, number: 1),
  ];
  int _activeSaleSessionId = 1;
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
  bool _hasRegisterSessionError = false;
  bool _hasCheckoutSettingsError = false;
  RegisterSession? _availableRegisterSession;
  RegisterSession? _activeRegisterSession;
  int _catalogRequestVersion = 0;
  Future<void>? _catalogLoadFuture;
  ProductQuery? _catalogLoadFutureQuery;
  Future<void>? _checkoutSettingsLoadFuture;
  Future<void>? _registerSessionLoadFuture;
  ProductQuery _query = const ProductQuery(
    availability: ProductAvailabilityFilter.active,
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
  bool get hasRegisterSessionError => _hasRegisterSessionError;
  bool get hasCheckoutSettingsError => _hasCheckoutSettingsError;
  RegisterSession? get availableRegisterSession => _availableRegisterSession;
  RegisterSession? get activeRegisterSession => _activeRegisterSession;
  ProductQuery get query => _query;
  bool get requireOpeningCash => _checkoutSettings?.requireOpeningCash ?? true;
  bool get allowOverselling => _checkoutSettings?.allowOverselling ?? false;
  bool get preventSellingAtLoss =>
      _checkoutSettings?.preventSellingAtLoss ?? true;
  bool get shouldShowPrintInvoiceCheckbox =>
      _checkoutSettings != null && !_checkoutSettings!.autoPrintReceipts;
  bool get shouldShowShareInvoiceCheckbox => shouldShowPrintInvoiceCheckbox;
  bool get enableCashPayments => _checkoutSettings?.enableCashPayments ?? true;
  bool get enableCardPayments => _checkoutSettings?.enableCardPayments ?? true;
  bool get enableTransferPayments =>
      _checkoutSettings?.enableTransferPayments ?? true;
  bool get requireCardPaymentReceipt =>
      _checkoutSettings?.requireCardPaymentReceipt ?? false;
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

  void _notifyChanged() {
    notifyListeners();
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
  final Map<String, String> _checkoutIdempotencyKeysBySignature = {};
  SaleDiscountPreview? discountPreview;
  bool isLoadingDiscountPreview = false;
  bool hasDiscountPreviewError = false;
  bool printInvoiceAfterPayment = false;
  bool shareInvoiceAfterPayment = false;
  int discountPreviewRequestVersion = 0;

  bool get isEmpty => cart.isEmpty;

  void touch() {
    updatedAt = DateTime.now();
    _checkoutIdempotencyKeysBySignature.clear();
  }

  String checkoutIdempotencyKeyFor(SaleCheckoutDraft draft) {
    return _checkoutIdempotencyKeysBySignature.putIfAbsent(
      _checkoutSignature(draft),
      _newCheckoutIdempotencyKey,
    );
  }
}

String _newCheckoutIdempotencyKey() {
  return 'checkout:${generateAnalyticsEventId()}';
}

String _checkoutSignature(SaleCheckoutDraft draft) {
  return jsonEncode(draft.toJson());
}
