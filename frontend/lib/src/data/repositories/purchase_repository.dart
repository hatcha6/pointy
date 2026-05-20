import '../../core/result.dart';
import '../models/purchase_submission.dart';
import '../services/pos_api_service.dart';

class PurchaseRepository {
  const PurchaseRepository(this._service);

  final PosApiService _service;

  Future<Result<PurchaseOrderPage>> loadPurchaseOrders({
    required PurchaseOrderQuery query,
    int page = 1,
  }) async {
    try {
      return Ok(await _service.fetchPurchaseOrders(query: query, page: page));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseOrder>> loadPurchaseOrder(int purchaseOrderId) async {
    try {
      return Ok(await _service.fetchPurchaseOrder(purchaseOrderId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<SupplierPaymentPage>> loadSupplierPayments({
    int? supplierId,
    int? purchaseOrderId,
    int page = 1,
  }) async {
    try {
      return Ok(
        await _service.fetchSupplierPayments(
          supplierId: supplierId,
          purchaseOrderId: purchaseOrderId,
          page: page,
        ),
      );
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<SupplierPayment>> createSupplierPayment(
    SupplierPaymentDraft draft,
  ) async {
    try {
      return Ok(await _service.createSupplierPayment(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<double?>> loadLastProductCost(int productId) async {
    try {
      return Ok(await _service.fetchLastProductCost(productId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseSubmission>> submitDraft(
    List<PurchaseDraftLine> lines, {
    required bool receiveImmediately,
    required int supplierId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    double shippingCost = 0,
    double customsCost = 0,
    double handlingCost = 0,
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
  }) async {
    if (lines.isEmpty) {
      return Error(Exception('purchase draft is empty'));
    }

    try {
      final draft = PurchaseOrderDraft.fromDraftLines(
        lines,
        supplierId: supplierId,
        supplierInvoiceNumber: supplierInvoiceNumber,
        supplierInvoiceDate: supplierInvoiceDate,
        shippingCost: shippingCost,
        customsCost: customsCost,
        handlingCost: handlingCost,
        landedCostAllocationMethod: landedCostAllocationMethod,
      );
      final order = await _service.createPurchaseOrder(draft);
      final submittedOrder = await _service.submitPurchaseOrder(order.id);
      if (!receiveImmediately) {
        return Ok(submittedOrder.toSubmission());
      }
      final receivedOrder = await _service.receivePurchaseOrder(order.id);
      return Ok(receivedOrder.toSubmission());
    } on Exception catch (error) {
      return Error(error);
    }
  }

  Future<Result<PurchaseOrder>> submitOrder(int purchaseOrderId) async {
    try {
      return Ok(await _service.submitPurchaseOrder(purchaseOrderId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseOrder>> receiveOrder(int purchaseOrderId) async {
    try {
      return Ok(await _service.receivePurchaseOrder(purchaseOrderId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseOrder>> receiveLines({
    required int purchaseOrderId,
    required PurchaseReceiveDraft draft,
  }) async {
    try {
      return Ok(
        await _service.receivePurchaseOrder(purchaseOrderId, draft: draft),
      );
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseOrder>> cancelOrder(int purchaseOrderId) async {
    try {
      return Ok(await _service.cancelPurchaseOrder(purchaseOrderId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseOrder>> returnItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) async {
    try {
      return Ok(
        await _service.returnPurchaseOrderItems(
          purchaseOrderId: purchaseOrderId,
          draft: draft,
        ),
      );
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseOrder>> refundItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) async {
    try {
      return Ok(
        await _service.refundPurchaseOrderItems(
          purchaseOrderId: purchaseOrderId,
          draft: draft,
        ),
      );
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<PurchaseOrder>> exchangeItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) async {
    try {
      return Ok(
        await _service.exchangePurchaseOrderItems(
          purchaseOrderId: purchaseOrderId,
          draft: draft,
        ),
      );
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
