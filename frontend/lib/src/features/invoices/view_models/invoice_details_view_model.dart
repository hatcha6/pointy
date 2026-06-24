import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/print_audit_event.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../data/services/payment_proof_printer.dart';

class InvoiceDetailsViewModel extends ChangeNotifier {
  InvoiceDetailsViewModel(
    this._saleRepository, {
    required PrintingRepository printingRepository,
    required ShopSettingsRepository shopSettingsRepository,
    required SaleOrder initialOrder,
    AnalyticsEngine? analyticsEngine,
  }) : _printingRepository = printingRepository,
       _shopSettingsRepository = shopSettingsRepository,
       _order = initialOrder,
       _analyticsEngine = analyticsEngine;

  final SaleRepository _saleRepository;
  final PrintingRepository _printingRepository;
  final ShopSettingsRepository _shopSettingsRepository;
  final AnalyticsEngine? _analyticsEngine;
  late final PaymentProofPrinter _paymentProofPrinter = PaymentProofPrinter(
    printingRepository: _printingRepository,
    shopSettingsRepository: _shopSettingsRepository,
  );

  SaleOrder _order;
  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isRecordingPayment = false;
  bool _isConverting = false;
  final Map<String, String> _idempotencyKeysBySignature = {};

  SaleOrder get order => _order;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isRecordingPayment => _isRecordingPayment;
  bool get isConverting => _isConverting;

  Future<void> loadInvoice() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _saleRepository.loadOrder(_order.id);
    switch (result) {
      case Ok<SaleOrder>(value: final order):
        _order = order;
      case Error<SaleOrder>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Records a payment against this (credit) invoice and reloads the order on
  /// success. Cards are allowed — pass [cardReceiptUrl] for the card method.
  /// Uses a signature-based idempotency key so a double-tap is a server no-op.
  /// When [printProof] is set, prints a "سند قبض" proof for the just-recorded
  /// payment after the record succeeds.
  Future<bool> recordPayment({
    required PaymentMethod method,
    required double amount,
    String cardReceiptUrl = '',
    bool printProof = false,
  }) async {
    if (_isRecordingPayment) {
      return false;
    }

    _isRecordingPayment = true;
    notifyListeners();

    final signature = _paymentSignature(
      method: method,
      amount: amount,
      cardReceiptUrl: cardReceiptUrl,
    );
    final result = await _saleRepository.recordInvoicePayment(
      saleOrderId: _order.id,
      method: method.apiValue,
      amount: amount,
      cardReceiptUrl: cardReceiptUrl,
      idempotencyKey: _idempotencyKeyFor(signature),
    );
    final didRecord = result is Ok<SaleOrder>;
    if (didRecord) {
      _clearIdempotencyKey(signature);
      _order = result.value;
    }

    _isRecordingPayment = false;
    notifyListeners();

    if (didRecord && printProof) {
      // Best-effort: the payment is already recorded, so a failed/declined
      // print must not flip the result to failure.
      await _printPaymentProof(method: method, amount: amount);
    }
    return didRecord;
  }

  /// Builds and prints a "سند قبض" proof for the most-recent payment on the
  /// (reloaded) order. The newest payment is the one with the highest id; the
  /// order's `balanceDue` is the customer's balance after this payment.
  Future<void> _printPaymentProof({
    required PaymentMethod method,
    required double amount,
  }) async {
    const labels = OrderDocumentLabels.arabic();
    final payment = _order.payments.isEmpty
        ? null
        : _order.payments.reduce((a, b) => a.id >= b.id ? a : b);
    final proof = PaymentProof(
      kind: PaymentProofKind.receipt,
      reference: payment != null ? '${payment.id}' : '${_order.id}',
      partyName: (_order.customerName?.trim().isNotEmpty ?? false)
          ? _order.customerName!.trim()
          : labels.walkInCustomer,
      partyContact: _order.customerPhone?.trim().isNotEmpty == true
          ? _order.customerPhone!.trim()
          : _order.customerNumber,
      relatedDocumentNumber: _order.receiptNumber,
      amount: payment?.amount ?? amount,
      method: labels.paymentMethodLabel(method),
      commissionAmount: payment?.commissionAmount,
      externalReference: payment?.externalReference,
      balanceAfter: _order.balanceDue,
      createdAt: payment?.createdAt ?? DateTime.now(),
    );

    await _paymentProofPrinter.printProof(
      proof: proof,
      paymentId: payment?.id ?? _order.id,
      paymentKind: PrintAuditPaymentKind.customer,
    );
  }

  /// Converts this OPEN quotation into a standard or credit sale, optionally
  /// taking a down-payment ([amountReceived]). Returns the NEW order on success
  /// so the caller can navigate to it, or null on failure.
  Future<SaleOrder?> convertQuotation({
    required SaleType saleType,
    double? amountReceived,
  }) async {
    if (_isConverting) {
      return null;
    }

    _isConverting = true;
    notifyListeners();

    final signature = [
      'convert-quotation',
      _order.id,
      saleType.apiValue,
      amountReceived?.toStringAsFixed(2) ?? '',
    ].join(':');
    final result = await _saleRepository.convertQuotation(
      _order.id,
      saleType: saleType,
      amountReceived: amountReceived,
      idempotencyKey: _idempotencyKeyFor(signature),
    );

    _isConverting = false;
    switch (result) {
      case Ok<SaleOrder>(value: final newOrder):
        _clearIdempotencyKey(signature);
        _trackQuotationConverted(newOrder, saleType: saleType);
        notifyListeners();
        return newOrder;
      case Error<SaleOrder>():
        notifyListeners();
        return null;
    }
  }

  void _trackQuotationConverted(
    SaleOrder newOrder, {
    required SaleType saleType,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'sales.quotation.converted',
      sessionId: _orderSessionId(_order),
      entityType: 'sale_order',
      entityId: _order.id,
      attributes: {
        ..._orderAttributes(_order),
        'new_order_id': newOrder.id,
        'new_sale_type': saleType.apiValue,
        'source': 'invoice_details_screen',
      },
      metrics: {'total': _order.total, 'line_count': _order.lines.length},
    );
  }

  String _paymentSignature({
    required PaymentMethod method,
    required double amount,
    required String cardReceiptUrl,
  }) {
    return [
      'invoice-payment',
      _order.id,
      method.apiValue,
      amount.toStringAsFixed(2),
      cardReceiptUrl.trim(),
    ].join(':');
  }

  String _idempotencyKeyFor(String signature) {
    return _idempotencyKeysBySignature.putIfAbsent(
      signature,
      () => 'invoice-payment:${generateAnalyticsEventId()}',
    );
  }

  void _clearIdempotencyKey(String signature) {
    _idempotencyKeysBySignature.remove(signature);
  }

  Future<bool> requestReprint(SaleOrder order) async {
    final shopSettings = await _loadShopSettings();
    final result = await _printingRepository.printSaleInvoice(
      order: order,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(shopSettings),
    );
    if (result.isSuccess) {
      _trackReceiptReprintCompleted(order);
      return true;
    }
    _trackReceiptReprintFailed(order);
    return false;
  }

  Future<OrderDocumentActionStatus> shareInvoice(SaleOrder order) async {
    final shopSettings = await _loadShopSettings();
    final status = await _printingRepository.shareSaleInvoice(
      order: order,
      shopSettings: shopSettings,
      shopLogoBytes: await _loadShopLogoBytes(shopSettings),
    );
    if (status == OrderDocumentActionStatus.completed) {
      _trackInvoiceShared(order);
    }
    return status;
  }

  Future<bool> voidInvoice(SaleOrder order, String reason) async {
    final result = await _saleRepository.voidOrder(
      saleOrderId: order.id,
      draft: SaleVoidDraft(reason: reason),
    );
    return _handleOrderAdjustmentResult(
      result,
      eventName: 'invoices.order_void.completed',
      order: order,
      reason: reason,
    );
  }

  Future<bool> returnItems(
    SaleOrder order,
    List<SaleReturnLineDraft> lines,
    String reason,
  ) async {
    final result = await _saleRepository.returnItems(
      saleOrderId: order.id,
      draft: SaleReturnDraft(lines: lines, reason: reason),
    );
    return _handleOrderAdjustmentResult(
      result,
      eventName: 'invoices.order_return.completed',
      order: order,
      reason: reason,
      metrics: {
        'returned_quantity': lines.fold<double>(
          0,
          (sum, line) => sum + line.quantity,
        ),
        'returned_line_count': lines.length,
      },
    );
  }

  bool _handleOrderAdjustmentResult(
    Result<SaleOrder> result, {
    required String eventName,
    required SaleOrder order,
    required String reason,
    Map<String, num> metrics = const {},
  }) {
    switch (result) {
      case Ok<SaleOrder>(value: final updatedOrder):
        _order = updatedOrder;
        _trackOrderAdjustmentCompleted(
          eventName: eventName,
          originalOrder: order,
          updatedOrder: updatedOrder,
          reason: reason,
          metrics: metrics,
        );
        notifyListeners();
        return true;
      case Error<SaleOrder>():
        return false;
    }
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

  void _trackReceiptReprintCompleted(SaleOrder order) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'sales.receipt.reprint.completed',
      sessionId: _orderSessionId(order),
      entityType: 'sale_order',
      entityId: order.id,
      attributes: {
        ..._orderAttributes(order),
        'source': 'invoice_details_screen',
      },
      metrics: {'total': order.total, 'line_count': order.lines.length},
    );
  }

  void _trackInvoiceShared(SaleOrder order) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'sales.invoice.pdf.shared',
      sessionId: _orderSessionId(order),
      entityType: 'sale_order',
      entityId: order.id,
      attributes: {
        ..._orderAttributes(order),
        'source': 'invoice_details_screen',
      },
      metrics: {'total': order.total, 'line_count': order.lines.length},
    );
  }

  void _trackReceiptReprintFailed(SaleOrder order) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'sales.receipt.reprint.failed',
      severity: AnalyticsEventSeverity.warning,
      sessionId: _orderSessionId(order),
      entityType: 'sale_order',
      entityId: order.id,
      attributes: {
        ..._orderAttributes(order),
        'source': 'invoice_details_screen',
      },
      metrics: {'total': order.total, 'line_count': order.lines.length},
      flushImmediately: true,
    );
  }

  void _trackOrderAdjustmentCompleted({
    required String eventName,
    required SaleOrder originalOrder,
    required SaleOrder updatedOrder,
    required String reason,
    Map<String, num> metrics = const {},
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: eventName,
      sessionId: _orderSessionId(originalOrder),
      entityType: 'sale_order',
      entityId: originalOrder.id,
      attributes: {
        ..._orderAttributes(originalOrder),
        'updated_status': updatedOrder.status,
        'reason_present': reason.trim().isNotEmpty,
        'source': 'invoice_details_screen',
      },
      metrics: {
        'total': originalOrder.total,
        'line_count': originalOrder.lines.length,
        ...metrics,
      },
    );
  }

  Map<String, Object?> _orderAttributes(SaleOrder order) {
    return {
      'sale_order_id': order.id,
      if (order.receiptNumber?.isNotEmpty == true)
        'receipt_number': order.receiptNumber,
      if (order.registerSession != null)
        'register_session_id': order.registerSession,
      if (order.registerSessionNumber?.isNotEmpty == true)
        'session_number': order.registerSessionNumber,
      'status': order.status,
    };
  }

  String? _orderSessionId(SaleOrder order) {
    final registerSession = order.registerSession;
    return registerSession == null ? null : 'register:$registerSession';
  }
}
