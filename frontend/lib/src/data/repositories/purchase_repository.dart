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
    SupplierPaymentDraft draft, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () =>
          _service.createSupplierPayment(draft, idempotencyKey: idempotencyKey),
    );
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

  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async {
    return Result.guard(() => _service.fetchProductCostSummary(productId));
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
    int? variantId,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchPurchaseAdjustmentHistory(
        adjustmentType: adjustmentType,
        supplierId: supplierId,
        productId: productId,
        variantId: variantId,
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

  Future<Result<({double? suggestedPrice, double? markupPercent})>>
  loadPricingSuggestion(double unitCost, {int? productId}) async {
    return Result.guard(
      () => _service.fetchPricingSuggestion(unitCost, productId: productId),
    );
  }

  Future<Result<PurchaseSubmission>> submitDraft(
    List<PurchaseDraftLine> lines, {
    required bool receiveImmediately,
    required int supplierId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
    double extraDiscountAmount = 0,
    String? idempotencyKey,
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
        landedCostEntries: landedCostEntries,
        landedCostAllocationMethod: landedCostAllocationMethod,
        discountCode: discountCode,
        extraDiscountAmount: extraDiscountAmount,
      );
      final order = await _service.createPurchaseOrder(
        draft,
        idempotencyKey: _scopedIdempotencyKey(idempotencyKey, 'create'),
      );
      final submittedOrder = await _service.submitPurchaseOrder(
        order.id,
        idempotencyKey: _scopedIdempotencyKey(idempotencyKey, 'submit'),
      );
      if (!receiveImmediately) {
        return submittedOrder.toSubmission();
      }
      final receiveDraft = PurchaseReceiveDraft(
        lines: [
          for (final line in submittedOrder.lines)
            if (line.receivableQuantity > 0)
              PurchaseReceiveLineDraft(
                purchaseLineId: line.id,
                quantityReceived: line.receivableQuantity,
                quantityDamaged: 0,
                expiryDate: line.expiryDate,
              ),
        ],
      );
      final receivedOrder = await _service.receivePurchaseOrder(
        submittedOrder.id,
        draft: receiveDraft,
        idempotencyKey: _scopedIdempotencyKey(idempotencyKey, 'receive'),
      );
      return receivedOrder.toSubmission();
    });
  }

  /// One-tap POS cash purchase: a single atomic backend call creates the
  /// order, receives it into stock, pays it in cash, and books the register
  /// pay-out — unlike [submitDraft], which needs the wider purchasing
  /// permissions and never touches the drawer.
  Future<Result<PurchaseSubmission>> submitPosCashPurchase(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    String? idempotencyKey,
  }) async {
    if (lines.isEmpty) {
      return Error(Exception('purchase draft is empty'));
    }
    return Result.guard(() async {
      final draft = PurchaseOrderDraft.fromDraftLines(
        lines,
        supplierId: supplierId,
      );
      final order = await _service.createPosCashPurchase(
        draft,
        idempotencyKey: _scopedIdempotencyKey(idempotencyKey, 'pos-cash'),
      );
      return order.toSubmission();
    });
  }

  /// Saves edits to an existing **draft** purchase order without committing it
  /// (it stays a draft). Replaces the order's lines, landed costs and
  /// editor-managed fields with [lines] and the supplied values. The backend
  /// rejects this for any non-draft order.
  Future<Result<PurchaseOrder>> updateDraftOrder(
    int purchaseOrderId,
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
    double extraDiscountAmount = 0,
  }) async {
    if (lines.isEmpty) {
      return Error(Exception('purchase draft is empty'));
    }

    return Result.guard(() {
      final draft = PurchaseOrderDraft.fromDraftLines(
        lines,
        supplierId: supplierId,
        supplierInvoiceNumber: supplierInvoiceNumber,
        supplierInvoiceDate: supplierInvoiceDate,
        landedCostEntries: landedCostEntries,
        landedCostAllocationMethod: landedCostAllocationMethod,
        discountCode: discountCode,
        extraDiscountAmount: extraDiscountAmount,
      );
      return _service.updatePurchaseOrder(purchaseOrderId, draft);
    });
  }

  Future<Result<PurchaseOrder>> submitOrder(
    int purchaseOrderId, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.submitPurchaseOrder(
        purchaseOrderId,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<PurchaseOrder>> receiveOrder(
    int purchaseOrderId, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.receivePurchaseOrder(
        purchaseOrderId,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<PurchaseOrder>> receiveLines({
    required int purchaseOrderId,
    required PurchaseReceiveDraft draft,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.receivePurchaseOrder(
        purchaseOrderId,
        draft: draft,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<PurchaseOrder>> cancelOrder(
    int purchaseOrderId, {
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.cancelPurchaseOrder(
        purchaseOrderId,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<PurchaseOrder>> returnItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.returnPurchaseOrderItems(
        purchaseOrderId: purchaseOrderId,
        draft: draft,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<PurchaseOrder>> refundItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.refundPurchaseOrderItems(
        purchaseOrderId: purchaseOrderId,
        draft: draft,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<PurchaseOrder>> exchangeItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.exchangePurchaseOrderItems(
        purchaseOrderId: purchaseOrderId,
        draft: draft,
        idempotencyKey: idempotencyKey,
      ),
    );
  }
}

String? _scopedIdempotencyKey(String? key, String scope) {
  final normalized = key?.trim() ?? '';
  if (normalized.isEmpty) {
    return null;
  }
  return '$normalized:$scope';
}
