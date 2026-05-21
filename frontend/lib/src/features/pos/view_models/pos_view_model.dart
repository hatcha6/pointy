import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/cart_line.dart';
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

part 'pos_cart_actions.dart';
part 'pos_catalog_actions.dart';
part 'pos_barcode_actions.dart';
part 'pos_checkout.dart';
part 'pos_register_session_actions.dart';

enum RegisterSessionGateStatus {
  loading,
  noOpenSession,
  openSessionAvailable,
  active,
}

enum BarcodeScanStatus { idle, resolving, found, notFound, error }

enum PosProductSelectionStatus { added, chooseVariant, unavailable, error }

class PosProductSelectionResult {
  const PosProductSelectionResult._({
    required this.status,
    this.variants = const [],
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

  final PosProductSelectionStatus status;
  final List<ProductVariant> variants;
}

class PosViewModel extends ChangeNotifier {
  PosViewModel(
    this._catalogRepository,
    this._registerSessionRepository,
    this._saleRepository,
    this._shopSettingsRepository,
    this._printingRepository,
  );

  final CatalogRepository _catalogRepository;
  final RegisterSessionRepository _registerSessionRepository;
  final SaleRepository _saleRepository;
  final ShopSettingsRepository _shopSettingsRepository;
  final PrintingRepository _printingRepository;

  CatalogRepository get catalogRepository => _catalogRepository;

  List<Product> _products = [];
  final List<CartLine> _cart = [];
  ShopSettings? _checkoutSettings;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isLoadingRegisterSession = false;
  bool _isLoadingCheckoutSettings = false;
  bool _isStartingRegisterSession = false;
  bool _isClosingRegisterSession = false;
  bool _isCreatingCashMovement = false;
  bool _isCheckingOut = false;
  BarcodeScanStatus _barcodeScanStatus = BarcodeScanStatus.idle;
  bool _printInvoiceAfterPayment = false;
  Customer? _selectedCustomer;
  bool _hasMoreProducts = true;
  int _nextProductPage = 1;
  String? _errorMessage;
  String _couponCode = '';
  SaleDiscountPreview? _discountPreview;
  bool _isLoadingDiscountPreview = false;
  bool _hasDiscountPreviewError = false;
  String? _lastScannedBarcode;
  String? _lastScannedProductName;
  bool _hasRegisterSessionError = false;
  bool _hasCheckoutSettingsError = false;
  RegisterSession? _availableRegisterSession;
  RegisterSession? _activeRegisterSession;
  int _catalogRequestVersion = 0;
  int _discountPreviewRequestVersion = 0;
  Future<void>? _catalogLoadFuture;
  ProductQuery? _catalogLoadFutureQuery;
  Future<void>? _checkoutSettingsLoadFuture;
  Future<void>? _registerSessionLoadFuture;
  ProductQuery _query = const ProductQuery(
    availability: ProductAvailabilityFilter.active,
  );

  List<Product> get products => List.unmodifiable(_products);
  List<CartLine> get cart => List.unmodifiable(_cart);
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
  bool get shouldShowPrintInvoiceCheckbox =>
      _checkoutSettings != null && !_checkoutSettings!.autoPrintReceipts;
  bool get enableCashPayments => _checkoutSettings?.enableCashPayments ?? true;
  bool get enableCardPayments => _checkoutSettings?.enableCardPayments ?? true;
  bool get enableTransferPayments =>
      _checkoutSettings?.enableTransferPayments ?? true;

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
        if (result.value.autoPrintReceipts) {
          _printInvoiceAfterPayment = false;
        }
      case Error<ShopSettings>():
        _checkoutSettings = null;
        _printInvoiceAfterPayment = false;
        _hasCheckoutSettingsError = true;
    }

    _isLoadingCheckoutSettings = false;
    _notifyChanged();
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
}
