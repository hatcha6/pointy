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
  bool _isRecordingPayment = false;
  bool _hasLoadError = false;
  bool _hasStatusError = false;
  bool _hasAdjustmentError = false;
  bool _hasPaymentError = false;

  PurchaseOrder get order => _order;
  bool get isLoading => _isLoading;
  bool get isChangingStatus => _isChangingStatus;
  bool get isAdjusting => _isAdjusting;
  bool get isRecordingPayment => _isRecordingPayment;
  bool get hasLoadError => _hasLoadError;
  bool get hasStatusError => _hasStatusError;
  bool get hasAdjustmentError => _hasAdjustmentError;
  bool get hasPaymentError => _hasPaymentError;

  bool get canSubmit => _order.status == 'draft';
  bool get canReceive =>
      (_order.status == 'submitted' ||
          _order.status == 'partial' ||
          _order.status == 'partially_received') &&
      _order.hasOpenReceiving;
  bool get canCancel =>
      _order.status == 'draft' || _order.status == 'submitted';
  bool get canReturn => _order.canReturn;
  bool get canRefund => _order.canRefund;
  bool get canExchange => _order.canExchange;
  bool get canRecordPayment =>
      _order.supplierId != null && _order.balanceDue > 0.005;

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

  Future<bool> receiveLines({
    required List<PurchaseReceiveLineDraft> lines,
    String note = '',
  }) {
    return _changeStatus(
      _purchaseRepository.receiveLines(
        purchaseOrderId: _order.id,
        draft: PurchaseReceiveDraft(lines: lines, note: note),
      ),
    );
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
    required List<PurchaseReplacementLineDraft> replacementLines,
    String reason = '',
  }) {
    return _adjustOrder(
      _purchaseRepository.exchangeItems(
        purchaseOrderId: _order.id,
        draft: PurchaseAdjustmentDraft(
          lines: lines,
          replacementLines: replacementLines,
          reason: reason,
        ),
      ),
    );
  }

  Future<bool> recordPayment({
    required SupplierPaymentMethod method,
    required double amount,
    String reference = '',
    String notes = '',
  }) async {
    if (_isRecordingPayment) {
      return false;
    }

    _isRecordingPayment = true;
    _hasPaymentError = false;
    notifyListeners();

    final result = await _purchaseRepository.createSupplierPayment(
      SupplierPaymentDraft(
        supplierId: _order.supplierId,
        purchaseOrderId: _order.id,
        amount: amount,
        method: method,
        reference: reference,
        notes: notes,
      ),
    );
    final didRecord = switch (result) {
      Ok<SupplierPayment>() => true,
      Error<SupplierPayment>() => false,
    };
    if (didRecord) {
      final reloadResult = await _purchaseRepository.loadPurchaseOrder(
        _order.id,
      );
      switch (reloadResult) {
        case Ok<PurchaseOrder>():
          _order = reloadResult.value;
        case Error<PurchaseOrder>():
          _hasLoadError = true;
      }
    } else {
      _hasPaymentError = true;
    }

    _isRecordingPayment = false;
    notifyListeners();
    return didRecord;
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
