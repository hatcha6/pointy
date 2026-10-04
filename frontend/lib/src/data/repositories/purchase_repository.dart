import '../../core/result.dart';
import '../models/purchase_submission.dart';
import '../models/purchase_suggestion.dart';
import '../models/stock_batch.dart';
import '../models/stock_unit.dart';
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

  Future<Result<PurchaseSuggestionSet>> loadPurchaseSuggestions({
    required int supplierId,
    List<int> variantIds = const [],
    int limit = 8,
  }) async {
    return Result.guard(
      () => _service.fetchPurchaseSuggestions(
        supplierId: supplierId,
        variantIds: variantIds,
        limit: limit,
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

    /// Where the goods will land. Null lets the server use the shop's own
    /// place, which is the only one most shops have and the answer every
    /// purchase order got before this existed.
    int? warehouseId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
    double extraDiscountAmount = 0,
    String? idempotencyKey,

    /// The currency the supplier invoiced in; blank means the shop's own.
    String currencyCode = '',

    /// A rate the buyer typed. Null lets the server read the rate as of the
    /// supplier's invoice date.
    double? exchangeRate,

    /// Set after the buyer has seen and confirmed the backend's cost warnings.
    bool acknowledgeCostWarnings = false,
  }) async {
    if (lines.isEmpty) {
      return Error(Exception('purchase draft is empty'));
    }

    return Result.guard(() async {
      final draft = PurchaseOrderDraft.fromDraftLines(
        lines,
        supplierId: supplierId,
        warehouseId: warehouseId,
        supplierInvoiceNumber: supplierInvoiceNumber,
        supplierInvoiceDate: supplierInvoiceDate,
        landedCostEntries: landedCostEntries,
        landedCostAllocationMethod: landedCostAllocationMethod,
        discountCode: discountCode,
        extraDiscountAmount: extraDiscountAmount,
        currencyCode: currencyCode,
        exchangeRate: exchangeRate,
      );
      final order = await _service.createPurchaseOrder(
        draft,
        idempotencyKey: _scopedIdempotencyKey(idempotencyKey, 'create'),
        acknowledgeCostWarnings: acknowledgeCostWarnings,
      );
      final submittedOrder = await _service.submitPurchaseOrder(
        order.id,
        idempotencyKey: _scopedIdempotencyKey(idempotencyKey, 'submit'),
      );
      if (!receiveImmediately) {
        return submittedOrder.toSubmission();
      }
      // Handsets and lots are received where they are scanned. Receiving them
      // here, blind, either fails (serials) or files them under a lot the
      // server invents (batches); the caller opens the receiving dialog on
      // this order instead.
      if (submittedOrder.receiptNeedsIdentifiers) {
        return submittedOrder.toSubmission(awaitsIdentifiers: true);
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
    bool acknowledgeCostWarnings = false,
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
      return _service.updatePurchaseOrder(
        purchaseOrderId,
        draft,
        acknowledgeCostWarnings: acknowledgeCostWarnings,
      );
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

  /// The handsets of [variantId] that could go back to the supplier: in stock
  /// and standing where the order's delivery landed.
  ///
  /// Deliberately wider than the till's list: a pack in a recalled lot and a
  /// handset still «بانتظار المعرّف» are exactly what goes back to a supplier,
  /// and the server accepts both on a supplier return (and nowhere else).
  ///
  /// The same `stock-units` read the transfer pick sheet makes through
  /// `TrackedStockRepository.loadUnits`, offered here so the order screen —
  /// opened from purchasing, a supplier's page or a product's history — needs
  /// no second repository threaded through every one of those routes.
  Future<Result<StockUnitPage>> loadReturnableUnits({
    required int variantId,
    int? warehouseId,
    String code = '',
  }) {
    return Result.guard(
      () => _service.fetchStockUnits(
        variantId: variantId,
        warehouseId: warehouseId,
        status: StockUnitStatus.inStock,
        code: code,
      ),
    );
  }

  /// The lots of [variantId] holding goods where the order's delivery landed,
  /// recalled and expired ones included — sending a recalled lot back is the
  /// normal end of a recall, so the supplier return lists it rather than
  /// hiding it the way the till does.
  Future<Result<StockBatchPage>> loadReturnableLots({
    required int variantId,
    int? warehouseId,
  }) {
    return Result.guard(
      () => _service.fetchStockBatches(
        variantId: variantId,
        warehouseId: warehouseId,
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
