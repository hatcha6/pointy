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

    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return PurchaseOrderPage.fromJson(decoded);
    }
    return const PurchaseOrderPage(orders: [], hasMore: false);
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

  Future<PurchaseOrder> receivePurchaseOrder(int purchaseOrderId) async {
    final response = await _session.post(
      'purchase-orders/$purchaseOrderId/receive/',
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
