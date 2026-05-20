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

  SupplierContact _supplier;
  List<PurchaseOrder> _purchaseHistory = [];
  List<PurchaseAdjustmentHistoryEntry> _adjustmentHistory = [];
  bool _isLoadingSupplier = false;
  bool _isLoadingHistory = false;
  bool _isLoadingAdjustments = false;
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
    notifyListeners();

    final result = await _purchaseRepository.loadSupplierPurchaseHistory(
      supplierId: _supplier.id,
    );
    switch (result) {
      case Ok<PurchaseOrderPage>():
        _purchaseHistory = result.value.orders;
      case Error<PurchaseOrderPage>():
        _purchaseHistory = [];
        _hasHistoryError = true;
    }

    _isLoadingHistory = false;
    notifyListeners();
  }

  Future<void> loadAdjustments() async {
    _isLoadingAdjustments = true;
    _hasAdjustmentError = false;
    notifyListeners();

    final returnFuture = _purchaseRepository.loadPurchaseAdjustmentHistory(
      supplierId: _supplier.id,
      adjustmentType: PurchaseAdjustmentType.returnItems,
    );
    final refundFuture = _purchaseRepository.loadPurchaseAdjustmentHistory(
      supplierId: _supplier.id,
      adjustmentType: PurchaseAdjustmentType.refund,
    );
    final returnResult = await returnFuture;
    final refundResult = await refundFuture;
    final entries = <PurchaseAdjustmentHistoryEntry>[];
    var hasError = false;

    switch (returnResult) {
      case Ok<PurchaseAdjustmentHistoryPage>():
        entries.addAll(returnResult.value.entries);
      case Error<PurchaseAdjustmentHistoryPage>():
        hasError = true;
    }
    switch (refundResult) {
      case Ok<PurchaseAdjustmentHistoryPage>():
        entries.addAll(refundResult.value.entries);
      case Error<PurchaseAdjustmentHistoryPage>():
        hasError = true;
    }

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
    _adjustmentHistory = entries;
    _hasAdjustmentError = hasError;
    _isLoadingAdjustments = false;
    notifyListeners();
  }
}
