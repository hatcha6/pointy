import 'package:flutter/material.dart';

import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart'
    show SupplierPayment, SupplierPaymentMethod, SupplierPaymentPage;
import '../../../data/models/sale_order.dart' show PaymentMethod;
import '../../../data/repositories/payments_repository.dart';
import '../models/payment_record.dart';

/// The two ledgers the Payments hub (الخزينة) shows.
enum PaymentsHubSegment { customer, supplier }

/// Drives the Payments hub: two paginated, filterable ledgers (customer
/// money-IN and supplier money-OUT). One date window and method filter apply to
/// the active segment; switching segments lazily loads the other ledger.
class PaymentsHubViewModel extends ChangeNotifier {
  PaymentsHubViewModel(this._repository) {
    loadCustomerPayments();
  }

  final PaymentsRepository _repository;

  PaymentsHubSegment _segment = PaymentsHubSegment.customer;

  // Customer (money-IN) ledger state.
  List<CustomerPaymentRecord> _customerPayments = [];
  bool _isLoadingCustomer = false;
  bool _isLoadingMoreCustomer = false;
  bool _hasMoreCustomer = true;
  bool _hasCustomerError = false;
  bool _customerLoaded = false;
  int _nextCustomerPage = 1;
  DateTimeRange? _customerRange;
  PaymentMethod? _customerMethod;

  // Supplier (money-OUT) ledger state.
  List<SupplierPayment> _supplierPayments = [];
  bool _isLoadingSupplier = false;
  bool _isLoadingMoreSupplier = false;
  bool _hasMoreSupplier = true;
  bool _hasSupplierError = false;
  bool _supplierLoaded = false;
  int _nextSupplierPage = 1;
  DateTimeRange? _supplierRange;
  // Supplier payments can be credit/refund too, so this is the supplier enum,
  // not the customer PaymentMethod (which only covers cash/card/transfer).
  SupplierPaymentMethod? _supplierMethod;

  PaymentsHubSegment get segment => _segment;

  List<CustomerPaymentRecord> get customerPayments =>
      List.unmodifiable(_customerPayments);
  bool get isLoadingCustomer => _isLoadingCustomer;
  bool get isLoadingMoreCustomer => _isLoadingMoreCustomer;
  bool get hasMoreCustomer => _hasMoreCustomer;
  bool get hasCustomerError => _hasCustomerError;
  DateTimeRange? get customerRange => _customerRange;
  PaymentMethod? get customerMethod => _customerMethod;

  List<SupplierPayment> get supplierPayments =>
      List.unmodifiable(_supplierPayments);
  bool get isLoadingSupplier => _isLoadingSupplier;
  bool get isLoadingMoreSupplier => _isLoadingMoreSupplier;
  bool get hasMoreSupplier => _hasMoreSupplier;
  bool get hasSupplierError => _hasSupplierError;
  DateTimeRange? get supplierRange => _supplierRange;
  SupplierPaymentMethod? get supplierMethod => _supplierMethod;

  void selectSegment(PaymentsHubSegment segment) {
    if (_segment == segment) {
      return;
    }
    _segment = segment;
    notifyListeners();
    if (segment == PaymentsHubSegment.supplier && !_supplierLoaded) {
      loadSupplierPayments();
    } else if (segment == PaymentsHubSegment.customer && !_customerLoaded) {
      loadCustomerPayments();
    }
  }

  // ----- Customer money-IN -------------------------------------------------

  Future<void> loadCustomerPayments() async {
    _isLoadingCustomer = true;
    _hasCustomerError = false;
    _hasMoreCustomer = true;
    _nextCustomerPage = 1;
    notifyListeners();

    final result = await _repository.loadCustomerPayments(
      method: _customerMethod?.apiValue,
      paidAtGte: _customerRange?.start,
      paidAtLte: _endOfDay(_customerRange?.end),
      page: _nextCustomerPage,
    );
    switch (result) {
      case Ok<CustomerPaymentPage>(value: final page):
        _customerPayments = page.payments;
        _hasMoreCustomer = page.hasMore;
        _nextCustomerPage = 2;
      case Error<CustomerPaymentPage>():
        _customerPayments = [];
        _hasMoreCustomer = false;
        _hasCustomerError = true;
    }

    _isLoadingCustomer = false;
    _customerLoaded = true;
    notifyListeners();
  }

  Future<void> loadMoreCustomerPayments() async {
    if (_isLoadingCustomer || _isLoadingMoreCustomer || !_hasMoreCustomer) {
      return;
    }
    _isLoadingMoreCustomer = true;
    notifyListeners();

    final result = await _repository.loadCustomerPayments(
      method: _customerMethod?.apiValue,
      paidAtGte: _customerRange?.start,
      paidAtLte: _endOfDay(_customerRange?.end),
      page: _nextCustomerPage,
    );
    switch (result) {
      case Ok<CustomerPaymentPage>(value: final page):
        _customerPayments = [..._customerPayments, ...page.payments];
        _hasMoreCustomer = page.hasMore;
        _nextCustomerPage += 1;
      case Error<CustomerPaymentPage>():
        _hasMoreCustomer = false;
    }

    _isLoadingMoreCustomer = false;
    notifyListeners();
  }

  void setCustomerRange(DateTimeRange? range) {
    _customerRange = range;
    loadCustomerPayments();
  }

  void setCustomerMethod(PaymentMethod? method) {
    _customerMethod = method;
    loadCustomerPayments();
  }

  // ----- Supplier money-OUT ------------------------------------------------

  Future<void> loadSupplierPayments() async {
    _isLoadingSupplier = true;
    _hasSupplierError = false;
    _hasMoreSupplier = true;
    _nextSupplierPage = 1;
    notifyListeners();

    final result = await _repository.loadSupplierPayments(
      method: _supplierMethod?.apiValue,
      paidAtGte: _supplierRange?.start,
      paidAtLte: _endOfDay(_supplierRange?.end),
      page: _nextSupplierPage,
    );
    switch (result) {
      case Ok<SupplierPaymentPage>(value: final page):
        _supplierPayments = page.payments;
        _hasMoreSupplier = page.hasMore;
        _nextSupplierPage = 2;
      case Error<SupplierPaymentPage>():
        _supplierPayments = [];
        _hasMoreSupplier = false;
        _hasSupplierError = true;
    }

    _isLoadingSupplier = false;
    _supplierLoaded = true;
    notifyListeners();
  }

  Future<void> loadMoreSupplierPayments() async {
    if (_isLoadingSupplier || _isLoadingMoreSupplier || !_hasMoreSupplier) {
      return;
    }
    _isLoadingMoreSupplier = true;
    notifyListeners();

    final result = await _repository.loadSupplierPayments(
      method: _supplierMethod?.apiValue,
      paidAtGte: _supplierRange?.start,
      paidAtLte: _endOfDay(_supplierRange?.end),
      page: _nextSupplierPage,
    );
    switch (result) {
      case Ok<SupplierPaymentPage>(value: final page):
        _supplierPayments = [..._supplierPayments, ...page.payments];
        _hasMoreSupplier = page.hasMore;
        _nextSupplierPage += 1;
      case Error<SupplierPaymentPage>():
        _hasMoreSupplier = false;
    }

    _isLoadingMoreSupplier = false;
    notifyListeners();
  }

  void setSupplierRange(DateTimeRange? range) {
    _supplierRange = range;
    loadSupplierPayments();
  }

  void setSupplierMethod(SupplierPaymentMethod? method) {
    _supplierMethod = method;
    loadSupplierPayments();
  }

  /// Refreshes whichever ledger is active.
  Future<void> refreshActive() {
    return _segment == PaymentsHubSegment.customer
        ? loadCustomerPayments()
        : loadSupplierPayments();
  }

  /// The end-of-day boundary so an inclusive ``paid_at <= end`` window also
  /// catches payments recorded later in the selected day.
  DateTime? _endOfDay(DateTime? day) {
    if (day == null) {
      return null;
    }
    return DateTime(day.year, day.month, day.day, 23, 59, 59, 999);
  }
}
