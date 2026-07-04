import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/purchase_repository.dart';

class SupplierDetailsViewModel extends ChangeNotifier {
  SupplierDetailsViewModel({
    required ContactRepository contactRepository,
    required PurchaseRepository purchaseRepository,
    required SupplierContact initialSupplier,
  }) : _contactRepository = contactRepository,
       _purchaseRepository = purchaseRepository,
       _supplier = initialSupplier {
    load();
  }

  final ContactRepository _contactRepository;
  final PurchaseRepository _purchaseRepository;

  ContactRepository get repository => _contactRepository;

  SupplierContact _supplier;
  List<PurchaseOrder> _purchaseHistory = [];
  List<PurchaseAdjustmentHistoryEntry> _adjustmentHistory = [];
  bool _isLoadingSupplier = false;
  bool _isLoadingHistory = false;
  bool _isLoadingAdjustments = false;
  bool _isLoadingMoreHistory = false;
  bool _isLoadingMoreAdjustments = false;
  bool _hasMorePurchaseHistory = true;
  bool _hasMoreReturnAdjustments = true;
  bool _hasMoreRefundAdjustments = true;
  int _nextPurchaseHistoryPage = 1;
  int _nextReturnAdjustmentPage = 1;
  int _nextRefundAdjustmentPage = 1;
  bool _hasSupplierError = false;
  bool _hasHistoryError = false;
  bool _hasAdjustmentError = false;

  SupplierContact get supplier => _supplier;
  List<PurchaseOrder> get purchaseHistory =>
      List.unmodifiable(_purchaseHistory);
  List<PurchaseAdjustmentHistoryEntry> get adjustmentHistory =>
      List.unmodifiable(_adjustmentHistory);
  bool get isLoadingSupplier => _isLoadingSupplier;
  bool get isLoadingHistory => _isLoadingHistory;
  bool get isLoadingAdjustments => _isLoadingAdjustments;
  bool get isLoadingMoreHistory => _isLoadingMoreHistory;
  bool get isLoadingMoreAdjustments => _isLoadingMoreAdjustments;
  bool get hasMorePurchaseHistory => _hasMorePurchaseHistory;
  bool get hasMoreAdjustments =>
      _hasMoreReturnAdjustments || _hasMoreRefundAdjustments;
  bool get hasSupplierError => _hasSupplierError;
  bool get hasHistoryError => _hasHistoryError;
  bool get hasAdjustmentError => _hasAdjustmentError;

  Future<void> load() async {
    await Future.wait([
      loadSupplier(),
      loadPurchaseHistory(),
      loadAdjustments(),
    ]);
  }

  /// Adopts the supplier returned by the edit sheet (which performed the
  /// PATCH itself, mirroring the create flow) into this view's state.
  void applyUpdatedSupplier(SupplierContact supplier) {
    _supplier = supplier;
    notifyListeners();
  }

  Future<void> loadSupplier() async {
    _isLoadingSupplier = true;
    _hasSupplierError = false;
    notifyListeners();

    final result = await _contactRepository.loadSupplier(_supplier.id);
    switch (result) {
      case Ok<SupplierContact>():
        _supplier = result.value;
      case Error<SupplierContact>():
        _hasSupplierError = true;
    }

    _isLoadingSupplier = false;
    notifyListeners();
  }

  Future<void> loadPurchaseHistory() async {
    _isLoadingHistory = true;
    _hasHistoryError = false;
    _hasMorePurchaseHistory = true;
    _nextPurchaseHistoryPage = 1;
    notifyListeners();

    final result = await _purchaseRepository.loadSupplierPurchaseHistory(
      supplierId: _supplier.id,
      page: _nextPurchaseHistoryPage,
    );
    switch (result) {
      case Ok<PurchaseOrderPage>():
        _purchaseHistory = result.value.orders;
        _hasMorePurchaseHistory = result.value.hasMore;
        _nextPurchaseHistoryPage = 2;
      case Error<PurchaseOrderPage>():
        _purchaseHistory = [];
        _hasMorePurchaseHistory = false;
        _hasHistoryError = true;
    }

    _isLoadingHistory = false;
    notifyListeners();
  }

  Future<void> loadMorePurchaseHistory() async {
    if (_isLoadingHistory ||
        _isLoadingMoreHistory ||
        !_hasMorePurchaseHistory) {
      return;
    }

    _isLoadingMoreHistory = true;
    notifyListeners();

    final result = await _purchaseRepository.loadSupplierPurchaseHistory(
      supplierId: _supplier.id,
      page: _nextPurchaseHistoryPage,
    );
    switch (result) {
      case Ok<PurchaseOrderPage>():
        _purchaseHistory = [..._purchaseHistory, ...result.value.orders];
        _hasMorePurchaseHistory = result.value.hasMore;
        _nextPurchaseHistoryPage += 1;
      case Error<PurchaseOrderPage>():
        _hasMorePurchaseHistory = false;
        _hasHistoryError = true;
    }

    _isLoadingMoreHistory = false;
    notifyListeners();
  }

  Future<void> loadAdjustments() async {
    _isLoadingAdjustments = true;
    _hasAdjustmentError = false;
    _hasMoreReturnAdjustments = true;
    _hasMoreRefundAdjustments = true;
    _nextReturnAdjustmentPage = 1;
    _nextRefundAdjustmentPage = 1;
    notifyListeners();

    final returnFuture = _purchaseRepository.loadPurchaseAdjustmentHistory(
      supplierId: _supplier.id,
      adjustmentType: PurchaseAdjustmentType.returnItems,
      page: _nextReturnAdjustmentPage,
    );
    final refundFuture = _purchaseRepository.loadPurchaseAdjustmentHistory(
      supplierId: _supplier.id,
      adjustmentType: PurchaseAdjustmentType.refund,
      page: _nextRefundAdjustmentPage,
    );
    final returnResult = await returnFuture;
    final refundResult = await refundFuture;
    final entries = <PurchaseAdjustmentHistoryEntry>[];
    var hasError = false;

    switch (returnResult) {
      case Ok<PurchaseAdjustmentHistoryPage>():
        entries.addAll(returnResult.value.entries);
        _hasMoreReturnAdjustments = returnResult.value.hasMore;
        _nextReturnAdjustmentPage = 2;
      case Error<PurchaseAdjustmentHistoryPage>():
        _hasMoreReturnAdjustments = false;
        hasError = true;
    }
    switch (refundResult) {
      case Ok<PurchaseAdjustmentHistoryPage>():
        entries.addAll(refundResult.value.entries);
        _hasMoreRefundAdjustments = refundResult.value.hasMore;
        _nextRefundAdjustmentPage = 2;
      case Error<PurchaseAdjustmentHistoryPage>():
        _hasMoreRefundAdjustments = false;
        hasError = true;
    }

    _sortAdjustmentHistory(entries);
    _adjustmentHistory = entries;
    _hasAdjustmentError = hasError;
    _isLoadingAdjustments = false;
    notifyListeners();
  }

  Future<void> loadMoreAdjustments() async {
    if (_isLoadingAdjustments ||
        _isLoadingMoreAdjustments ||
        !hasMoreAdjustments) {
      return;
    }

    _isLoadingMoreAdjustments = true;
    notifyListeners();

    final entries = [..._adjustmentHistory];
    var hasError = false;

    if (_hasMoreReturnAdjustments) {
      final result = await _purchaseRepository.loadPurchaseAdjustmentHistory(
        supplierId: _supplier.id,
        adjustmentType: PurchaseAdjustmentType.returnItems,
        page: _nextReturnAdjustmentPage,
      );
      switch (result) {
        case Ok<PurchaseAdjustmentHistoryPage>():
          entries.addAll(result.value.entries);
          _hasMoreReturnAdjustments = result.value.hasMore;
          _nextReturnAdjustmentPage += 1;
        case Error<PurchaseAdjustmentHistoryPage>():
          _hasMoreReturnAdjustments = false;
          hasError = true;
      }
    }

    if (_hasMoreRefundAdjustments) {
      final result = await _purchaseRepository.loadPurchaseAdjustmentHistory(
        supplierId: _supplier.id,
        adjustmentType: PurchaseAdjustmentType.refund,
        page: _nextRefundAdjustmentPage,
      );
      switch (result) {
        case Ok<PurchaseAdjustmentHistoryPage>():
          entries.addAll(result.value.entries);
          _hasMoreRefundAdjustments = result.value.hasMore;
          _nextRefundAdjustmentPage += 1;
        case Error<PurchaseAdjustmentHistoryPage>():
          _hasMoreRefundAdjustments = false;
          hasError = true;
      }
    }

    _sortAdjustmentHistory(entries);
    _adjustmentHistory = entries;
    _hasAdjustmentError = _hasAdjustmentError || hasError;
    _isLoadingMoreAdjustments = false;
    notifyListeners();
  }

  void _sortAdjustmentHistory(List<PurchaseAdjustmentHistoryEntry> entries) {
    entries.sort((left, right) {
      final leftDate = left.createdAt;
      final rightDate = right.createdAt;
      if (leftDate == null && rightDate == null) {
        return right.id.compareTo(left.id);
      }
      if (leftDate == null) {
        return 1;
      }
      if (rightDate == null) {
        return -1;
      }
      return rightDate.compareTo(leftDate);
    });
  }
}
