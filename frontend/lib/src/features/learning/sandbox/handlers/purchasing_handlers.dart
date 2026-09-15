import '../sandbox_payloads.dart';
import '../sandbox_request.dart';
import '../sandbox_shop.dart';

/// Purchase orders: raise one, submit it, receive against it.
SandboxReply handlePurchasing(SandboxShop shop, SandboxRequest request) {
  if (request.on('GET', 'purchase-orders/') != null) {
    return (
      200,
      page([
        for (final order in shop.purchaseOrders.reversed)
          // The list serializer drops lines, exactly as the real one does.
          purchaseOrderJson(order, includeLines: false),
      ]),
    );
  }
  if (request.on('POST', 'purchase-orders/') != null) {
    return (201, purchaseOrderJson(_create(shop, request)));
  }

  // Answered before the `{id}` routes below so the literal path wins over the
  // capture — `purchase-orders/suggestions/` is not order number "suggestions".
  for (final quiet in const [
    'purchase-orders/suggestions/',
    'purchase-orders/outstanding-received-not-paid/',
    'purchase-orders/adjustment-history/',
    'purchase-orders/product-cost-history/',
  ]) {
    if (request.on('GET', quiet) != null) {
      return (200, page(const []));
    }
  }
  if (request.on('GET', 'purchase-orders/last-cost/') != null) {
    final variant = shop.variantBySku(request.query('sku'));
    return (
      200,
      {'unit_cost': variant == null ? null : money(variant.unitPrice * 0.7)},
    );
  }
  if (request.on('GET', 'purchase-orders/pricing-suggestion/') != null ||
      request.on('GET', 'purchase-orders/product-cost-summary/') != null ||
      request.on('GET', 'purchase-orders/product-margin-impact/') != null) {
    return (200, const <String, Object?>{});
  }
  if (request.on('POST', 'purchase-orders/discount-preview/') != null) {
    final subtotal = _subtotal(shop, request);
    return (
      200,
      {
        'subtotal': money(subtotal),
        'discount_total': money(0),
        'total': money(subtotal),
        'applied_discounts': const <Object?>[],
        'rules_active': false,
      },
    );
  }

  final detail = request.on('GET', 'purchase-orders/{id}/');
  if (detail != null) {
    final order = shop.purchaseOrderById(int.tryParse(detail.first) ?? 0);
    return order == null
        ? (404, {'detail': 'not found'})
        : (200, purchaseOrderJson(order));
  }

  final update = request.on('PATCH', 'purchase-orders/{id}/');
  if (update != null) {
    final order = shop.purchaseOrderById(int.tryParse(update.first) ?? 0);
    if (order == null) {
      return (404, {'detail': 'not found'});
    }
    if (request.body.containsKey('lines')) {
      order.lines
        ..clear()
        ..addAll(_lines(shop, request));
    }
    shop.stateVersion++;
    return (200, purchaseOrderJson(order));
  }

  final submit = request.on('POST', 'purchase-orders/{id}/submit/');
  if (submit != null) {
    final order = shop.submitPurchaseOrder(int.tryParse(submit.first) ?? 0);
    return order == null
        ? (404, {'detail': 'not found'})
        : (200, purchaseOrderJson(order));
  }

  final receive = request.on('POST', 'purchase-orders/{id}/receive/');
  if (receive != null) {
    // Receiving speaks in *line* ids and `quantity_received`, not variant ids
    // and `quantity` — a different vocabulary from the cart, and reading the
    // cart's keys here silently receives nothing.
    final order = shop.receivePurchaseOrder(
      id: int.tryParse(receive.first) ?? 0,
      lines: [
        for (final row in request.rows('lines'))
          if (_lineOf(row) != null)
            (
              variantId: _lineOf(row)!,
              quantity: request.money(
                row['quantity_received'] ??
                    row['received_quantity'] ??
                    row['quantity'],
              ),
            ),
      ],
    );
    return order == null
        ? (404, {'detail': 'not found'})
        : (200, purchaseOrderJson(order));
  }

  final cancel = request.on('POST', 'purchase-orders/{id}/cancel/');
  if (cancel != null) {
    final order = shop.purchaseOrderById(int.tryParse(cancel.first) ?? 0);
    if (order == null) {
      return (404, {'detail': 'not found'});
    }
    order.status = 'cancelled';
    shop.stateVersion++;
    return (200, purchaseOrderJson(order));
  }

  return null;
}

SandboxPurchaseOrder _create(SandboxShop shop, SandboxRequest request) {
  return shop.createPurchaseOrder(
    supplierId: request.id('supplier') ?? 0,
    status: request.body['doc_status'] == 'submitted' ? 'submitted' : 'draft',
    lines: [
      for (final line in _lines(shop, request))
        (
          variantId: line.variantId,
          quantity: line.quantity,
          unitCost: line.unitCost,
        ),
    ],
  );
}

List<SandboxPurchaseOrderLine> _lines(
  SandboxShop shop,
  SandboxRequest request,
) {
  final lines = <SandboxPurchaseOrderLine>[];
  for (final row in request.rows('lines')) {
    final id = _variantOf(row);
    final variant = id == null ? null : shop.variantById(id);
    if (variant == null) {
      continue;
    }
    lines.add(
      SandboxPurchaseOrderLine(
        variantId: variant.id,
        sku: variant.sku,
        productName: shop.productOfVariant(variant.id)?.name ?? '',
        quantity: request.money(row['quantity']),
        unitCost: request.money(row['unit_cost']),
      ),
    );
  }
  return lines;
}

double _subtotal(SandboxShop shop, SandboxRequest request) {
  var subtotal = 0.0;
  for (final row in request.rows('lines')) {
    subtotal +=
        request.money(row['quantity']) * request.money(row['unit_cost']);
  }
  return subtotal;
}

int? _variantOf(Map<String, Object?> row) => int.tryParse(
  (row['product_variant'] ?? row['variant'] ?? row['id'])?.toString() ?? '',
);

/// The practice shop gives a purchase line the same id as its variant, so a
/// line id resolves straight back to the stock it moves.
int? _lineOf(Map<String, Object?> row) => int.tryParse(
  (row['purchase_line'] ?? row['id'] ?? row['product_variant'])?.toString() ??
      '',
);
