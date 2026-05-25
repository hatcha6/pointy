import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/customer_activity.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/sale_order_page.dart';
import '../../../data/repositories/contact_repository.dart';

class CustomerDetailsViewModel extends ChangeNotifier {
  CustomerDetailsViewModel({
    required ContactRepository contactRepository,
    required Customer initialCustomer,
  }) : _contactRepository = contactRepository,
       _customer = initialCustomer,
       _summary = CustomerSalesSummary.empty(initialCustomer.id) {
    load();
  }

  final ContactRepository _contactRepository;

  Customer _customer;
  CustomerSalesSummary _summary;
  List<SaleOrder> _orderHistory = [];
  List<CustomerAdjustmentHistoryEntry> _adjustmentHistory = [];
  bool _isLoadingCustomer = false;
  bool _isLoadingSummary = false;
  bool _isLoadingOrders = false;
  bool _isLoadingAdjustments = false;
  bool _isLoadingMoreOrders = false;
  bool _isLoadingMoreAdjustments = false;
  bool _hasMoreOrders = true;
  bool _hasMoreAdjustments = true;
  int _nextOrderPage = 1;
  int _nextAdjustmentPage = 1;
  bool _hasCustomerError = false;
  bool _hasSummaryError = false;
  bool _hasOrderError = false;
  bool _hasAdjustmentError = false;

  Customer get customer => _customer;
  CustomerSalesSummary get summary => _summary;
  List<SaleOrder> get orderHistory => List.unmodifiable(_orderHistory);
  List<CustomerAdjustmentHistoryEntry> get adjustmentHistory =>
      List.unmodifiable(_adjustmentHistory);
  bool get isLoadingCustomer => _isLoadingCustomer;
  bool get isLoadingSummary => _isLoadingSummary;
  bool get isLoadingOrders => _isLoadingOrders;
  bool get isLoadingAdjustments => _isLoadingAdjustments;
  bool get isLoadingMoreOrders => _isLoadingMoreOrders;
  bool get isLoadingMoreAdjustments => _isLoadingMoreAdjustments;
  bool get hasMoreOrders => _hasMoreOrders;
  bool get hasMoreAdjustments => _hasMoreAdjustments;
  bool get hasCustomerError => _hasCustomerError;
  bool get hasSummaryError => _hasSummaryError;
  bool get hasOrderError => _hasOrderError;
  bool get hasAdjustmentError => _hasAdjustmentError;

  Future<void> load() async {
    await Future.wait([
      loadCustomer(),
      loadSummary(),
      loadOrderHistory(),
      loadAdjustmentHistory(),
    ]);
  }

  Future<void> loadCustomer() async {
    _isLoadingCustomer = true;
    _hasCustomerError = false;
    notifyListeners();

    final result = await _contactRepository.loadCustomer(_customer.id);
    switch (result) {
      case Ok<Customer>():
        _customer = result.value;
      case Error<Customer>():
        _hasCustomerError = true;
    }

    _isLoadingCustomer = false;
    notifyListeners();
  }

  Future<void> loadSummary() async {
    _isLoadingSummary = true;
    _hasSummaryError = false;
    notifyListeners();

    final result = await _contactRepository.loadCustomerSalesSummary(
      _customer.id,
    );
    switch (result) {
      case Ok<CustomerSalesSummary>():
        _summary = result.value;
      case Error<CustomerSalesSummary>():
        _summary = CustomerSalesSummary.empty(_customer.id);
        _hasSummaryError = true;
    }

    _isLoadingSummary = false;
    notifyListeners();
  }

  Future<void> loadOrderHistory() async {
    _isLoadingOrders = true;
    _hasOrderError = false;
    _hasMoreOrders = true;
    _nextOrderPage = 1;
    notifyListeners();

    final result = await _contactRepository.loadCustomerOrderHistory(
      customerId: _customer.id,
      page: _nextOrderPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orderHistory = result.value.orders;
        _hasMoreOrders = result.value.hasMore;
        _nextOrderPage = 2;
      case Error<SaleOrderPage>():
        _orderHistory = [];
        _hasMoreOrders = false;
        _hasOrderError = true;
    }

    _isLoadingOrders = false;
    notifyListeners();
  }

  Future<void> loadMoreOrderHistory() async {
    if (_isLoadingOrders || _isLoadingMoreOrders || !_hasMoreOrders) {
      return;
    }

    _isLoadingMoreOrders = true;
    notifyListeners();

    final result = await _contactRepository.loadCustomerOrderHistory(
      customerId: _customer.id,
      page: _nextOrderPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orderHistory = [..._orderHistory, ...result.value.orders];
        _hasMoreOrders = result.value.hasMore;
        _nextOrderPage += 1;
      case Error<SaleOrderPage>():
        _hasMoreOrders = false;
        _hasOrderError = true;
    }

    _isLoadingMoreOrders = false;
    notifyListeners();
  }

  Future<void> loadAdjustmentHistory() async {
    _isLoadingAdjustments = true;
    _hasAdjustmentError = false;
    _hasMoreAdjustments = true;
    _nextAdjustmentPage = 1;
    notifyListeners();

    final result = await _contactRepository.loadCustomerAdjustmentHistory(
      customerId: _customer.id,
      page: _nextAdjustmentPage,
    );
    switch (result) {
      case Ok<CustomerAdjustmentHistoryPage>():
        _adjustmentHistory = result.value.entries;
        _hasMoreAdjustments = result.value.hasMore;
        _nextAdjustmentPage = 2;
      case Error<CustomerAdjustmentHistoryPage>():
        _adjustmentHistory = [];
        _hasMoreAdjustments = false;
        _hasAdjustmentError = true;
    }

    _isLoadingAdjustments = false;
    notifyListeners();
  }

  Future<void> loadMoreAdjustmentHistory() async {
    if (_isLoadingAdjustments ||
        _isLoadingMoreAdjustments ||
        !_hasMoreAdjustments) {
      return;
    }

    _isLoadingMoreAdjustments = true;
    notifyListeners();

    final result = await _contactRepository.loadCustomerAdjustmentHistory(
      customerId: _customer.id,
      page: _nextAdjustmentPage,
    );
    switch (result) {
      case Ok<CustomerAdjustmentHistoryPage>():
        _adjustmentHistory = [..._adjustmentHistory, ...result.value.entries];
        _hasMoreAdjustments = result.value.hasMore;
        _nextAdjustmentPage += 1;
      case Error<CustomerAdjustmentHistoryPage>():
        _hasMoreAdjustments = false;
        _hasAdjustmentError = true;
    }

    _isLoadingMoreAdjustments = false;
    notifyListeners();
  }
}
