import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/order_document_service.dart';

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

  SaleOrder _order;
  bool _isLoading = false;
  bool _hasLoadError = false;

  SaleOrder get order => _order;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;

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
        'returned_quantity': lines.fold<int>(
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
