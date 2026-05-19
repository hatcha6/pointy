import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/purchase_repository.dart';

class PurchaseOrderDetailsViewModel extends ChangeNotifier {
  PurchaseOrderDetailsViewModel(
    this._purchaseRepository, {
    required PurchaseOrder initialOrder,
  }) : _order = initialOrder {
    loadOrder();
  }

  final PurchaseRepository _purchaseRepository;

  PurchaseOrder _order;
  bool _isLoading = false;
  bool _isChangingStatus = false;
  bool _isAdjusting = false;
  bool _hasLoadError = false;
  bool _hasStatusError = false;
  bool _hasAdjustmentError = false;

  PurchaseOrder get order => _order;
  bool get isLoading => _isLoading;
  bool get isChangingStatus => _isChangingStatus;
  bool get isAdjusting => _isAdjusting;
  bool get hasLoadError => _hasLoadError;
  bool get hasStatusError => _hasStatusError;
  bool get hasAdjustmentError => _hasAdjustmentError;

  bool get canSubmit => _order.status == 'draft';
  bool get canReceive => _order.status == 'submitted';
  bool get canCancel =>
      _order.status == 'draft' || _order.status == 'submitted';
  bool get canReturn => _order.canReturn;
  bool get canRefund => _order.canRefund;
  bool get canExchange => _order.canExchange;

  Future<void> loadOrder() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _purchaseRepository.loadPurchaseOrder(_order.id);
    switch (result) {
      case Ok<PurchaseOrder>():
        _order = result.value;
      case Error<PurchaseOrder>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> submit() {
    return _changeStatus(_purchaseRepository.submitOrder(_order.id));
  }

  Future<bool> receive() {
    return _changeStatus(_purchaseRepository.receiveOrder(_order.id));
  }

  Future<bool> cancel() {
    return _changeStatus(_purchaseRepository.cancelOrder(_order.id));
  }

  Future<bool> returnItems({
    required List<PurchaseAdjustmentLineDraft> lines,
    String reason = '',
  }) {
    return _adjustOrder(
      _purchaseRepository.returnItems(
        purchaseOrderId: _order.id,
        draft: PurchaseAdjustmentDraft(lines: lines, reason: reason),
      ),
    );
  }

  Future<bool> refundItems({
    required List<PurchaseAdjustmentLineDraft> lines,
    String reason = '',
  }) {
    return _adjustOrder(
      _purchaseRepository.refundItems(
        purchaseOrderId: _order.id,
        draft: PurchaseAdjustmentDraft(lines: lines, reason: reason),
      ),
    );
  }

  Future<bool> exchangeItems({
    required List<PurchaseAdjustmentLineDraft> lines,
    String reason = '',
  }) {
    return _adjustOrder(
      _purchaseRepository.exchangeItems(
        purchaseOrderId: _order.id,
        draft: PurchaseAdjustmentDraft(lines: lines, reason: reason),
      ),
    );
  }

  Future<bool> _changeStatus(Future<Result<PurchaseOrder>> action) async {
    if (_isChangingStatus) {
      return false;
    }

    _isChangingStatus = true;
    _hasStatusError = false;
    notifyListeners();

    final result = await action;
    final didChange = switch (result) {
      Ok<PurchaseOrder>() => true,
      Error<PurchaseOrder>() => false,
    };
    switch (result) {
      case Ok<PurchaseOrder>():
        _order = result.value;
      case Error<PurchaseOrder>():
        _hasStatusError = true;
    }

    _isChangingStatus = false;
    notifyListeners();
    return didChange;
  }

  Future<bool> _adjustOrder(Future<Result<PurchaseOrder>> action) async {
    if (_isAdjusting) {
      return false;
    }

    _isAdjusting = true;
    _hasAdjustmentError = false;
    notifyListeners();

    final result = await action;
    final didAdjust = switch (result) {
      Ok<PurchaseOrder>() => true,
      Error<PurchaseOrder>() => false,
    };
    switch (result) {
      case Ok<PurchaseOrder>():
        _order = result.value;
      case Error<PurchaseOrder>():
        _hasAdjustmentError = true;
    }

    _isAdjusting = false;
    notifyListeners();
    return didAdjust;
  }
}
