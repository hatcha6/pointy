import 'package:flutter/foundation.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/api_session.dart';
import '../../../data/services/order_document_service.dart';

enum PurchaseOrderActionError {
  generic,
  permissionDenied,
  validationFailed,
  receivedStockUnavailable,
}

class PurchaseOrderDetailsViewModel extends ChangeNotifier {
  PurchaseOrderDetailsViewModel(
    this._purchaseRepository, {
    required PrintingRepository printingRepository,
    required ShopSettingsRepository shopSettingsRepository,
    required PurchaseOrder initialOrder,
    required AuthorizationCapabilities capabilities,
  }) : _printingRepository = printingRepository,
       _shopSettingsRepository = shopSettingsRepository,
       _order = initialOrder,
       _capabilities = capabilities {
    loadOrder();
  }

  final PurchaseRepository _purchaseRepository;
  final PrintingRepository _printingRepository;
  final ShopSettingsRepository _shopSettingsRepository;
  final AuthorizationCapabilities _capabilities;

  PurchaseOrder _order;
  bool _isLoading = false;
  bool _isChangingStatus = false;
  bool _isAdjusting = false;
  bool _isRecordingPayment = false;
  bool _isPrinting = false;
  bool _isSharing = false;
  bool _hasLoadError = false;
  bool _hasStatusError = false;
  bool _hasAdjustmentError = false;
  bool _hasPaymentError = false;
  PurchaseOrderActionError? _statusError;
  PurchaseOrderActionError? _adjustmentError;

  PurchaseOrder get order => _order;
  bool get isLoading => _isLoading;
  bool get isChangingStatus => _isChangingStatus;
  bool get isAdjusting => _isAdjusting;
  bool get isRecordingPayment => _isRecordingPayment;
  bool get isPrinting => _isPrinting;
  bool get isSharing => _isSharing;
  bool get hasLoadError => _hasLoadError;
  bool get hasStatusError => _hasStatusError;
  bool get hasAdjustmentError => _hasAdjustmentError;
  bool get hasPaymentError => _hasPaymentError;
  PurchaseOrderActionError? get statusError => _statusError;
  PurchaseOrderActionError? get adjustmentError => _adjustmentError;

  bool get canSubmit =>
      _capabilities.canEditDraftPurchaseOrder && _order.status == 'draft';
  bool get canReceive =>
      _capabilities.canReceivePurchaseOrder &&
      (_order.status == 'submitted' ||
          _order.status == 'partial' ||
          _order.status == 'partially_received') &&
      _order.hasOpenReceiving;
  bool get canCancel =>
      _capabilities.canCancelPurchaseOrder &&
      (_order.status == 'draft' || _order.status == 'submitted');
  bool get canReturn =>
      _capabilities.canAdjustPurchaseOrder && _order.canReturn;
  bool get canRefund =>
      _capabilities.canAdjustPurchaseOrder && _order.canRefund;
  bool get canExchange =>
      _capabilities.canAdjustPurchaseOrder && _order.canExchange;
  bool get canRecordPayment =>
      _order.supplierId != null && _order.balanceDue > 0.005;

  Future<bool> printOrder() async {
    if (_isPrinting) {
      return false;
    }
    _isPrinting = true;
    notifyListeners();

    final shopSettings = await _loadShopSettings();
    final result = await _printingRepository.printPurchaseOrder(
      order: _order,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(shopSettings),
    );

    _isPrinting = false;
    notifyListeners();
    return result.isSuccess;
  }

  Future<OrderDocumentActionStatus> shareOrder() async {
    if (_isSharing) {
      return OrderDocumentActionStatus.failed;
    }
    _isSharing = true;
    notifyListeners();

    final shopSettings = await _loadShopSettings();
    final result = await _printingRepository.sharePurchaseOrder(
      order: _order,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(shopSettings),
    );

    _isSharing = false;
    notifyListeners();
    return result;
  }

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
    _statusError = null;
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
        _statusError = _actionErrorFromException(result.exception);
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
    _adjustmentError = null;
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
        _adjustmentError = _actionErrorFromException(result.exception);
    }

    _isAdjusting = false;
    notifyListeners();
    return didAdjust;
  }

  PurchaseOrderActionError _actionErrorFromException(Exception exception) {
    if (exception is PosApiException) {
      if (exception.statusCode == 403) {
        return PurchaseOrderActionError.permissionDenied;
      }
      if (_isReceivedStockUnavailable(exception)) {
        return PurchaseOrderActionError.receivedStockUnavailable;
      }
      if (exception.statusCode == 400 || exception.statusCode == 409) {
        return PurchaseOrderActionError.validationFailed;
      }
    }
    return PurchaseOrderActionError.generic;
  }

  bool _isReceivedStockUnavailable(PosApiException exception) {
    final decoded = exception.decodedBody;
    final values = _flattenErrorValues(decoded).map((value) {
      return value.toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
    });
    return values.any((value) {
      return value.contains('received_stock_unavailable') ||
          value.contains('stock_unavailable') ||
          value.contains('stock_not_available') ||
          value.contains('insufficient_stock') ||
          value.contains('already_sold') ||
          (value.contains('sold') && value.contains('stock')) ||
          (value.contains('available') &&
              value.contains('stock') &&
              (value.contains('not') || value.contains('insufficient')));
    });
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

  Iterable<String> _flattenErrorValues(Object? value) sync* {
    if (value == null) {
      return;
    }
    if (value is String || value is num || value is bool) {
      yield value.toString();
      return;
    }
    if (value is List<Object?>) {
      for (final item in value) {
        yield* _flattenErrorValues(item);
      }
      return;
    }
    if (value is Map<Object?, Object?>) {
      for (final entry in value.entries) {
        yield entry.key.toString();
        yield* _flattenErrorValues(entry.value);
      }
    }
  }
}
