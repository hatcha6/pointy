import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';

class PurchaseOrderListViewModel extends ChangeNotifier {
  PurchaseOrderListViewModel(
    this._purchaseRepository,
    this._printingRepository,
    this._shopSettingsRepository,
  ) {
    loadOrders();
  }

  final PurchaseRepository _purchaseRepository;
  final PrintingRepository _printingRepository;
  final ShopSettingsRepository _shopSettingsRepository;

  List<PurchaseOrder> _orders = [];
  List<PurchaseOrder> _outstandingReceivedNotPaid = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isLoadingOutstanding = false;
  bool _isLoadingMoreOutstanding = false;
  bool _hasMoreOrders = true;
  bool _hasMoreOutstanding = true;
  bool _hasLoadError = false;
  bool _hasOutstandingError = false;
  int _nextPage = 1;
  int _nextOutstandingPage = 1;
  PurchaseOrderQuery _query = const PurchaseOrderQuery();

  List<PurchaseOrder> get orders => List.unmodifiable(_orders);
  List<PurchaseOrder> get outstandingReceivedNotPaid =>
      List.unmodifiable(_outstandingReceivedNotPaid);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadingOutstanding => _isLoadingOutstanding;
  bool get isLoadingMoreOutstanding => _isLoadingMoreOutstanding;
  bool get hasMoreOrders => _hasMoreOrders;
  bool get hasMoreOutstanding => _hasMoreOutstanding;
  bool get hasLoadError => _hasLoadError;
  bool get hasOutstandingError => _hasOutstandingError;
  PurchaseOrderQuery get query => _query;

  Future<void> loadOrders() async {
    _isLoading = true;
    _isLoadingOutstanding = true;
    _hasLoadError = false;
    _hasOutstandingError = false;
    _hasMoreOrders = true;
    _hasMoreOutstanding = true;
    _nextPage = 1;
    _nextOutstandingPage = 1;
    notifyListeners();

    // Each request publishes as soon as it lands so the order list renders
    // without waiting for the payables strip (and vice versa).
    final outstandingFuture = _loadOutstandingFirstPage();
    final result = await _purchaseRepository.loadPurchaseOrders(
      query: _query,
      page: _nextPage,
    );
    switch (result) {
      case Ok<PurchaseOrderPage>():
        _orders = result.value.orders;
        _hasMoreOrders = result.value.hasMore;
        _nextPage = 2;
      case Error<PurchaseOrderPage>():
        _orders = [];
        _hasLoadError = true;
        _hasMoreOrders = false;
    }
    _isLoading = false;
    notifyListeners();
    await outstandingFuture;
  }

  Future<void> _loadOutstandingFirstPage() async {
    final outstandingResult = await _purchaseRepository
        .loadOutstandingReceivedNotPaid(page: 1);
    switch (outstandingResult) {
      case Ok<PurchaseOrderPage>():
        _outstandingReceivedNotPaid = outstandingResult.value.orders;
        _hasMoreOutstanding = outstandingResult.value.hasMore;
        _nextOutstandingPage = 2;
      case Error<PurchaseOrderPage>():
        _outstandingReceivedNotPaid = [];
        _hasMoreOutstanding = false;
        _hasOutstandingError = true;
    }
    _isLoadingOutstanding = false;
    notifyListeners();
  }

  Future<void> loadMoreOrders() async {
    if (_isLoading || _isLoadingMore || !_hasMoreOrders) {
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    final result = await _purchaseRepository.loadPurchaseOrders(
      query: _query,
      page: _nextPage,
    );
    switch (result) {
      case Ok<PurchaseOrderPage>():
        _orders = [..._orders, ...result.value.orders];
        _hasMoreOrders = result.value.hasMore;
        _nextPage += 1;
      case Error<PurchaseOrderPage>():
        _hasLoadError = true;
        _hasMoreOrders = false;
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  Future<void> loadMoreOutstandingReceivedNotPaid() async {
    if (_isLoadingOutstanding ||
        _isLoadingMoreOutstanding ||
        !_hasMoreOutstanding) {
      return;
    }

    _isLoadingMoreOutstanding = true;
    notifyListeners();

    final result = await _purchaseRepository.loadOutstandingReceivedNotPaid(
      page: _nextOutstandingPage,
    );
    switch (result) {
      case Ok<PurchaseOrderPage>():
        _outstandingReceivedNotPaid = [
          ..._outstandingReceivedNotPaid,
          ...result.value.orders,
        ];
        _hasMoreOutstanding = result.value.hasMore;
        _nextOutstandingPage += 1;
      case Error<PurchaseOrderPage>():
        _hasOutstandingError = true;
        _hasMoreOutstanding = false;
    }

    _isLoadingMoreOutstanding = false;
    notifyListeners();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _query = _query.copyWith(search: search);
    await loadOrders();
  }

  Future<void> applyQuery(PurchaseOrderQuery query) async {
    if (query == _query) {
      return;
    }
    _query = query;
    await loadOrders();
  }

  Future<bool> printOrder(PurchaseOrder order) async {
    final completeOrder = await _loadCompleteOrder(order);
    if (completeOrder == null) {
      return false;
    }
    final shopSettings = await _loadShopSettings();
    final result = await _printingRepository.printPurchaseOrder(
      order: completeOrder,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(shopSettings),
    );
    return result.isSuccess;
  }

  Future<OrderDocumentActionStatus> shareOrder(PurchaseOrder order) async {
    final completeOrder = await _loadCompleteOrder(order);
    if (completeOrder == null) {
      return OrderDocumentActionStatus.failed;
    }
    final shopSettings = await _loadShopSettings();
    return _printingRepository.sharePurchaseOrder(
      order: completeOrder,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(shopSettings),
    );
  }

  Future<PurchaseOrder?> _loadCompleteOrder(PurchaseOrder order) async {
    final result = await _purchaseRepository.loadPurchaseOrder(order.id);
    return switch (result) {
      Ok<PurchaseOrder>(value: final loadedOrder) => loadedOrder,
      Error<PurchaseOrder>() => null,
    };
  }

  Future<ShopSettings?> _loadShopSettings() async {
    final result = await _shopSettingsRepository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final result = await _shopSettingsRepository.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }
}
