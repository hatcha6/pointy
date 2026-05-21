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
    return Result.guard(
      () => _service.fetchPurchaseOrders(query: query, page: page),
    );
  }

  Future<Result<PurchaseOrder>> loadPurchaseOrder(int purchaseOrderId) async {
    return Result.guard(() => _service.fetchPurchaseOrder(purchaseOrderId));
  }

  Future<Result<PurchaseDiscountPreview>> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async {
    return Result.guard(() => _service.previewPurchaseDiscounts(draft));
  }

  Future<Result<SupplierPaymentPage>> loadSupplierPayments({
    int? supplierId,
    int? purchaseOrderId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchSupplierPayments(
        supplierId: supplierId,
        purchaseOrderId: purchaseOrderId,
        page: page,
      ),
    );
  }

  Future<Result<SupplierPayment>> createSupplierPayment(
    SupplierPaymentDraft draft,
  ) async {
    return Result.guard(() => _service.createSupplierPayment(draft));
  }

  Future<Result<PurchaseOrderPage>> loadOutstandingReceivedNotPaid({
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchOutstandingReceivedNotPaidPurchases(page: page),
    );
  }

  Future<Result<PurchaseOrderPage>> loadSupplierPurchaseHistory({
    required int supplierId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchSupplierPurchaseHistory(
        supplierId: supplierId,
        page: page,
      ),
    );
  }

  Future<Result<ProductCostHistoryPage>> loadProductCostHistory({
    required int productId,
    int? variantId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchProductCostHistory(
        productId: productId,
        variantId: variantId,
        page: page,
      ),
    );
  }

  Future<Result<ProductMarginImpact?>> loadProductMarginImpact(
    int productId, {
    int? variantId,
  }) async {
    return Result.guard(
      () => _service.fetchProductMarginImpact(productId, variantId: variantId),
    );
  }

  Future<Result<PurchaseAdjustmentHistoryPage>> loadPurchaseAdjustmentHistory({
    PurchaseAdjustmentType? adjustmentType,
    int? supplierId,
    int? productId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchPurchaseAdjustmentHistory(
        adjustmentType: adjustmentType,
        supplierId: supplierId,
        productId: productId,
        page: page,
      ),
    );
  }

  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async {
    return Result.guard(
      () => _service.fetchLastProductCost(productId, variantId: variantId),
    );
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
    String discountCode = '',
  }) async {
    if (lines.isEmpty) {
      return Error(Exception('purchase draft is empty'));
    }

    return Result.guard(() async {
      final draft = PurchaseOrderDraft.fromDraftLines(
        lines,
        supplierId: supplierId,
        supplierInvoiceNumber: supplierInvoiceNumber,
        supplierInvoiceDate: supplierInvoiceDate,
        shippingCost: shippingCost,
        customsCost: customsCost,
        handlingCost: handlingCost,
        landedCostAllocationMethod: landedCostAllocationMethod,
        discountCode: discountCode,
      );
      final order = await _service.createPurchaseOrder(draft);
      final submittedOrder = await _service.submitPurchaseOrder(order.id);
      if (!receiveImmediately) {
        return submittedOrder.toSubmission();
      }
      final receivedOrder = await _service.receivePurchaseOrder(order.id);
      return receivedOrder.toSubmission();
    });
  }

  Future<Result<PurchaseOrder>> submitOrder(int purchaseOrderId) async {
    return Result.guard(() => _service.submitPurchaseOrder(purchaseOrderId));
  }

  Future<Result<PurchaseOrder>> receiveOrder(int purchaseOrderId) async {
    return Result.guard(() => _service.receivePurchaseOrder(purchaseOrderId));
  }

  Future<Result<PurchaseOrder>> receiveLines({
    required int purchaseOrderId,
    required PurchaseReceiveDraft draft,
  }) async {
    return Result.guard(
      () => _service.receivePurchaseOrder(purchaseOrderId, draft: draft),
    );
  }

  Future<Result<PurchaseOrder>> cancelOrder(int purchaseOrderId) async {
    return Result.guard(() => _service.cancelPurchaseOrder(purchaseOrderId));
  }

  Future<Result<PurchaseOrder>> returnItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) async {
    return Result.guard(
      () => _service.returnPurchaseOrderItems(
        purchaseOrderId: purchaseOrderId,
        draft: draft,
      ),
    );
  }

  Future<Result<PurchaseOrder>> refundItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) async {
    return Result.guard(
      () => _service.refundPurchaseOrderItems(
        purchaseOrderId: purchaseOrderId,
        draft: draft,
      ),
    );
  }

  Future<Result<PurchaseOrder>> exchangeItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) async {
    return Result.guard(
      () => _service.exchangePurchaseOrderItems(
        purchaseOrderId: purchaseOrderId,
        draft: draft,
      ),
    );
  }
}
