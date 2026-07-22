import '../models/contact.dart';
import '../models/purchase_submission.dart';
import 'api_session.dart';

class PurchasingApiClient {
  const PurchasingApiClient(this._session);

  final PosApiSession _session;

  Future<SupplierPage> fetchSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async {
    final queryParameters = query.toQueryParameters(page: page);
    if (queryParameters['ordering'] == ContactOrdering.name.apiValue) {
      queryParameters['ordering'] = 'name';
    }
    final response = await _session.get('suppliers/', query: queryParameters);
    _session.throwApiException(response, 'Supplier list failed with status');
    return SupplierPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SupplierContact> createSupplier(SupplierDraft draft) async {
    final response = await _session.post('suppliers/', body: draft.toJson());
    _session.throwApiException(response, 'Supplier create failed with status');
    return SupplierContact.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SupplierContact> fetchSupplier(int supplierId) async {
    final response = await _session.get('suppliers/$supplierId/');
    _session.throwApiException(response, 'Supplier detail failed with status');
    return SupplierContact.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SupplierContact> patchSupplier(
    int supplierId,
    Map<String, Object?> body,
  ) async {
    final response = await _session.patch('suppliers/$supplierId/', body: body);
    _session.throwApiException(response, 'Supplier update failed with status');
    return SupplierContact.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PurchaseOrderPage> fetchPurchaseOrders({
    required PurchaseOrderQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'purchase-orders/',
      query: query.toQueryParameters(page: page),
    );
    _session.throwApiException(
      response,
      'Purchase order list failed with status',
    );

    return PurchaseOrderPage.fromAny(_session.decodedBody(response));
  }

  Future<PurchaseOrderPage> fetchOutstandingReceivedNotPaidPurchases({
    int page = 1,
  }) async {
    final response = await _session.get(
      'purchase-orders/outstanding-received-not-paid/',
      query: {'page': '$page'},
    );
    _session.throwApiException(
      response,
      'Outstanding purchase order list failed with status',
    );
    return PurchaseOrderPage.fromAny(_session.decodedBody(response));
  }

  Future<PurchaseOrderPage> fetchSupplierPurchaseHistory({
    required int supplierId,
    int page = 1,
  }) async {
    final response = await _session.get(
      'suppliers/$supplierId/purchase-history/',
      query: {'page': '$page'},
    );
    _session.throwApiException(
      response,
      'Supplier purchase history failed with status',
    );
    return PurchaseOrderPage.fromAny(_session.decodedBody(response));
  }

  Future<ProductCostHistoryPage> fetchProductCostHistory({
    required int productId,
    int? variantId,
    int page = 1,
  }) async {
    final response = await _session.get(
      'purchase-orders/product-cost-history/',
      query: {
        'product': '$productId',
        if (variantId != null) 'variant': '$variantId',
        'page': '$page',
      },
    );
    _session.throwApiException(
      response,
      'Product cost history failed with status',
    );
    return ProductCostHistoryPage.fromAny(_session.decodedBody(response));
  }

  Future<List<VariantCostSummary>> fetchProductCostSummary(
    int productId,
  ) async {
    final response = await _session.get(
      'purchase-orders/product-cost-summary/',
      query: {'product': '$productId'},
    );
    _session.throwApiException(
      response,
      'Product cost summary failed with status',
    );
    return VariantCostSummary.listFromAny(_session.decodedBody(response));
  }

  Future<ProductMarginImpact?> fetchProductMarginImpact(
    int productId, {
    int? variantId,
  }) async {
    final response = await _session.get(
      'purchase-orders/product-margin-impact/',
      query: {
        'product': '$productId',
        if (variantId != null) 'variant': '$variantId',
      },
    );
    _session.throwApiException(
      response,
      'Product margin impact failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return ProductMarginImpact.fromJson(decoded);
  }

  Future<PurchaseAdjustmentHistoryPage> fetchPurchaseAdjustmentHistory({
    PurchaseAdjustmentType? adjustmentType,
    int? supplierId,
    int? productId,
    int? variantId,
    int page = 1,
  }) async {
    final response = await _session.get(
      'purchase-orders/adjustment-history/',
      query: {
        'page': '$page',
        if (adjustmentType != null) 'adjustment_type': adjustmentType.apiValue,
        if (supplierId != null) 'supplier': '$supplierId',
        if (productId != null) 'product': '$productId',
        if (variantId != null) 'variant': '$variantId',
      },
    );
    _session.throwApiException(
      response,
      'Purchase adjustment history failed with status',
    );
    return PurchaseAdjustmentHistoryPage.fromAny(
      _session.decodedBody(response),
    );
  }

  Future<PurchaseOrder> createPurchaseOrder(
    PurchaseOrderDraft draft, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'purchase-orders/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Purchase order create failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// One-tap drawer purchase from the POS: the backend creates the order,
  /// receives it into stock, pays it in full in cash, and records the linked
  /// register pay-out against the caller's open session — atomically.
  Future<PurchaseOrder> createPosCashPurchase(
    PurchaseOrderDraft draft, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'purchase-orders/pos-cash-purchase/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'POS cash purchase failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Replaces an existing draft purchase order with the edited [draft]. The
  /// backend rejects this for any non-draft order and replaces its lines and
  /// landed costs wholesale, recalculating totals.
  Future<PurchaseOrder> updatePurchaseOrder(
    int purchaseOrderId,
    PurchaseOrderDraft draft,
  ) async {
    final response = await _session.patch(
      'purchase-orders/$purchaseOrderId/',
      body: draft.toJson(forUpdate: true),
    );
    _session.throwApiException(
      response,
      'Purchase order update failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PurchaseDiscountPreview> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async {
    final response = await _session.post(
      'purchase-orders/discount-preview/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Purchase discount preview failed with status',
    );
    return PurchaseDiscountPreview.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PurchaseOrder> fetchPurchaseOrder(int purchaseOrderId) async {
    final response = await _session.get('purchase-orders/$purchaseOrderId/');
    _session.throwApiException(
      response,
      'Purchase order detail failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SupplierPaymentPage> fetchSupplierPayments({
    int? supplierId,
    int? purchaseOrderId,
    String? method,
    DateTime? paidAtGte,
    DateTime? paidAtLte,
    int page = 1,
  }) async {
    final response = await _session.get(
      'supplier-payments/',
      query: {
        'page': '$page',
        'ordering': '-paid_at',
        if (supplierId != null) 'supplier': '$supplierId',
        if (purchaseOrderId != null) 'purchase_order': '$purchaseOrderId',
        if (method != null && method.isNotEmpty) 'method': method,
        if (paidAtGte != null) 'paid_at__gte': paidAtGte.toIso8601String(),
        if (paidAtLte != null) 'paid_at__lte': paidAtLte.toIso8601String(),
      },
    );
    _session.throwApiException(
      response,
      'Supplier payment list failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return SupplierPaymentPage.fromJson(decoded);
    }
    return const SupplierPaymentPage(payments: [], hasMore: false);
  }

  Future<SupplierPayment> createSupplierPayment(
    SupplierPaymentDraft draft, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'supplier-payments/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Supplier payment create failed with status',
    );
    return SupplierPayment.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<double?> fetchLastProductCost(int productId, {int? variantId}) async {
    final response = await _session.get(
      'purchase-orders/last-cost/',
      query: {
        'product': '$productId',
        if (variantId != null) 'variant': '$variantId',
      },
    );
    _session.throwApiException(
      response,
      'Last purchase cost failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    // Prefer the per-base-unit cost: the raw unit_cost is in whatever unit the
    // last purchase used (162 for a carton), which would mis-price a line
    // bought in a different unit. Older backends only send unit_cost.
    final cost = decoded['base_unit_cost'] ?? decoded['unit_cost'];
    if (cost == null) {
      return null;
    }
    if (cost is num) {
      return cost.toDouble();
    }
    return double.tryParse(cost.toString());
  }

  /// Suggested sale price for [unitCost], using the shop's typical markup — used
  /// to pre-fill the reprice-siblings dialog. `suggestedPrice` is null when the
  /// cost is zero/unpriceable.
  Future<({double? suggestedPrice, double? markupPercent})> fetchPricingSuggestion(
    double unitCost,
  ) async {
    final response = await _session.get(
      'purchase-orders/pricing-suggestion/',
      query: {'unit_cost': unitCost.toStringAsFixed(2)},
    );
    _session.throwApiException(
      response,
      'Pricing suggestion failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is! Map<String, Object?>) {
      return (suggestedPrice: null, markupPercent: null);
    }
    double? asDouble(Object? value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    return (
      suggestedPrice: asDouble(decoded['suggested_price']),
      markupPercent: asDouble(decoded['markup_percent']),
    );
  }

  Future<PurchaseOrder> submitPurchaseOrder(
    int purchaseOrderId, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/submit/',
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Purchase order submit failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PurchaseOrder> receivePurchaseOrder(
    int purchaseOrderId, {
    PurchaseReceiveDraft? draft,
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/receive/',
      body: draft?.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Purchase order receive failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PurchaseOrder> cancelPurchaseOrder(
    int purchaseOrderId, {
    String? idempotencyKey,
  }) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/cancel/',
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(
      response,
      'Purchase order cancel failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PurchaseOrder> returnPurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) {
    return _adjustPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      actionPath: 'return-items',
      draft: draft,
      idempotencyKey: idempotencyKey,
      errorMessage: 'Purchase order return failed with status',
    );
  }

  Future<PurchaseOrder> refundPurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) {
    return _adjustPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      actionPath: 'refund-items',
      draft: draft,
      idempotencyKey: idempotencyKey,
      errorMessage: 'Purchase order refund failed with status',
    );
  }

  Future<PurchaseOrder> exchangePurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) {
    return _adjustPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      actionPath: 'exchange-items',
      draft: draft,
      idempotencyKey: idempotencyKey,
      errorMessage: 'Purchase order exchange failed with status',
    );
  }

  Future<PurchaseOrder> _adjustPurchaseOrderItems({
    required int purchaseOrderId,
    required String actionPath,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
    required String errorMessage,
  }) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/$actionPath/',
      body: draft.toJson(),
      idempotencyKey: idempotencyKey,
    );
    _session.throwApiException(response, errorMessage);
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
