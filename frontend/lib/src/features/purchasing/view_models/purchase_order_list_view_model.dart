import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/purchase_repository.dart';

class PurchaseOrderListViewModel extends ChangeNotifier {
  PurchaseOrderListViewModel(this._purchaseRepository) {
    loadOrders();
  }

  final PurchaseRepository _purchaseRepository;

  List<PurchaseOrder> _orders = [];
  List<PurchaseOrder> _outstandingReceivedNotPaid = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isLoadingOutstanding = false;
  bool _hasMoreOrders = true;
  bool _hasLoadError = false;
  bool _hasOutstandingError = false;
  int _nextPage = 1;
  PurchaseOrderQuery _query = const PurchaseOrderQuery();

  List<PurchaseOrder> get orders => List.unmodifiable(_orders);
  List<PurchaseOrder> get outstandingReceivedNotPaid =>
      List.unmodifiable(_outstandingReceivedNotPaid);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadingOutstanding => _isLoadingOutstanding;
  bool get hasMoreOrders => _hasMoreOrders;
  bool get hasLoadError => _hasLoadError;
  bool get hasOutstandingError => _hasOutstandingError;
  PurchaseOrderQuery get query => _query;

  Future<void> loadOrders() async {
    _isLoading = true;
    _isLoadingOutstanding = true;
    _hasLoadError = false;
    _hasOutstandingError = false;
    _hasMoreOrders = true;
    _nextPage = 1;
    notifyListeners();

    final outstandingResultFuture = _purchaseRepository
        .loadOutstandingReceivedNotPaid();
    final result = await _purchaseRepository.loadPurchaseOrders(
      query: _query,
      page: _nextPage,
    );
    final outstandingResult = await outstandingResultFuture;
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
    switch (outstandingResult) {
      case Ok<PurchaseOrderPage>():
        _outstandingReceivedNotPaid = outstandingResult.value.orders;
      case Error<PurchaseOrderPage>():
        _outstandingReceivedNotPaid = [];
        _hasOutstandingError = true;
    }

    _isLoading = false;
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
}
