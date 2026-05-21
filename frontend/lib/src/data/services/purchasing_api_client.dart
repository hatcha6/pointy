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
    int page = 1,
  }) async {
    final response = await _session.get(
      'purchase-orders/product-cost-history/',
      query: {'product': '$productId', 'page': '$page'},
    );
    _session.throwApiException(
      response,
      'Product cost history failed with status',
    );
    return ProductCostHistoryPage.fromAny(_session.decodedBody(response));
  }

  Future<ProductMarginImpact?> fetchProductMarginImpact(int productId) async {
    final response = await _session.get(
      'purchase-orders/product-margin-impact/',
      query: {'product': '$productId'},
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
    int page = 1,
  }) async {
    final response = await _session.get(
      'purchase-orders/adjustment-history/',
      query: {
        'page': '$page',
        if (adjustmentType != null) 'adjustment_type': adjustmentType.apiValue,
        if (supplierId != null) 'supplier': '$supplierId',
        if (productId != null) 'product': '$productId',
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

  Future<PurchaseOrder> createPurchaseOrder(PurchaseOrderDraft draft) async {
    final response = await _session.post(
      'purchase-orders/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Purchase order create failed with status',
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
    int page = 1,
  }) async {
    final response = await _session.get(
      'supplier-payments/',
      query: {
        'page': '$page',
        if (supplierId != null) 'supplier': '$supplierId',
        if (purchaseOrderId != null) 'purchase_order': '$purchaseOrderId',
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
    SupplierPaymentDraft draft,
  ) async {
    final response = await _session.post(
      'supplier-payments/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Supplier payment create failed with status',
    );
    return SupplierPayment.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<double?> fetchLastProductCost(int productId) async {
    final response = await _session.get(
      'purchase-orders/last-cost/',
      query: {'product': '$productId'},
    );
    _session.throwApiException(
      response,
      'Last purchase cost failed with status',
    );
    final decoded = _session.decodedBody(response);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final unitCost = decoded['unit_cost'];
    if (unitCost == null) {
      return null;
    }
    if (unitCost is num) {
      return unitCost.toDouble();
    }
    return double.tryParse(unitCost.toString());
  }

  Future<PurchaseOrder> submitPurchaseOrder(int purchaseOrderId) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/submit/',
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
  }) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/receive/',
      body: draft?.toJson(),
    );
    _session.throwApiException(
      response,
      'Purchase order receive failed with status',
    );
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<PurchaseOrder> cancelPurchaseOrder(int purchaseOrderId) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/cancel/',
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
  }) {
    return _adjustPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      actionPath: 'return-items',
      draft: draft,
      errorMessage: 'Purchase order return failed with status',
    );
  }

  Future<PurchaseOrder> refundPurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) {
    return _adjustPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      actionPath: 'refund-items',
      draft: draft,
      errorMessage: 'Purchase order refund failed with status',
    );
  }

  Future<PurchaseOrder> exchangePurchaseOrderItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
  }) {
    return _adjustPurchaseOrderItems(
      purchaseOrderId: purchaseOrderId,
      actionPath: 'exchange-items',
      draft: draft,
      errorMessage: 'Purchase order exchange failed with status',
    );
  }

  Future<PurchaseOrder> _adjustPurchaseOrderItems({
    required int purchaseOrderId,
    required String actionPath,
    required PurchaseAdjustmentDraft draft,
    required String errorMessage,
  }) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/$actionPath/',
      body: draft.toJson(),
    );
    _session.throwApiException(response, errorMessage);
    return PurchaseOrder.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
