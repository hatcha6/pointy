import '../sandbox_payloads.dart';
import '../sandbox_request.dart';
import '../sandbox_shop.dart';

/// Checkout, invoices, returns and exchanges.
SandboxReply handleSelling(SandboxShop shop, SandboxRequest request) {
  if (request.on('POST', 'orders/checkout/') != null) {
    return _checkout(shop, request);
  }

  if (request.on('POST', 'orders/discount-preview/') != null) {
    // Arithmetic, not a discount engine (§5): the practice shop prices the cart
    // at the seeded prices and applies nothing. `rules_active: false` is the
    // truth here — a training shop has no discount rules — and it lets the POS
    // latch that and stop asking.
    final subtotal = _subtotal(shop, request, 'lines');
    // ...except the cashier's own discount, which is not a rule and is plain
    // arithmetic. A practice shop that ignored it would show a trainee a total
    // that never moved, which is the opposite of what the lesson teaches.
    final extra = request
        .money(request.body['extra_discount_amount'])
        .clamp(0.0, subtotal);
    return (
      200,
      {
        'subtotal': money(subtotal),
        'discount_total': money(extra),
        'total': money(subtotal - extra),
        'extra_discount_amount': money(extra),
        'max_extra_discount_amount': money(subtotal),
        'applied_discounts': const <Object?>[],
        'unapplied_coupon_codes': const <Object?>[],
        'loss_lines': const <Object?>[],
        'rules_active': false,
        'rules_version': '${shop.stateVersion}',
      },
    );
  }

  if (request.on('GET', 'orders/') != null) {
    return (
      200,
      page([for (final order in shop.orders.reversed) orderJson(order)]),
    );
  }

  if (request.on('GET', 'orders/lookup/') != null) {
    final receipt = request.query('receipt_number');
    final order = shop.orderByReceipt(receipt);
    return order == null
        ? (404, {'detail': 'لا توجد فاتورة بهذا الرقم'})
        : (200, orderJson(order));
  }

  final detail = request.on('GET', 'orders/{id}/');
  if (detail != null) {
    final order = shop.orderById(int.tryParse(detail.first) ?? 0);
    return order == null
        ? (404, {'detail': 'not found'})
        : (200, orderJson(order));
  }

  final assign = request.on('POST', 'orders/{id}/assign-customer/');
  if (assign != null) {
    final order = shop.orderById(int.tryParse(assign.first) ?? 0);
    return order == null
        ? (404, {'detail': 'not found'})
        : (200, orderJson(order));
  }

  final recordPayment = request.on('POST', 'orders/{id}/record-payment/');
  if (recordPayment != null) {
    final order = shop.orderById(int.tryParse(recordPayment.first) ?? 0);
    if (order == null) {
      return (404, {'detail': 'not found'});
    }
    final amount = request.field('amount');
    final method = request.body['method']?.toString() ?? 'cash';
    order.payments.add(SandboxPayment(method: method, amount: amount));
    if (order.customerId != null) {
      shop.recordCustomerPayment(
        customerId: order.customerId!,
        amount: amount,
        method: method,
      );
    }
    return (201, orderJson(order));
  }

  final reprint = request.on('POST', 'orders/{id}/reprint/');
  if (reprint != null) {
    // Printing is simulated in training mode (§9). Nothing the shop can
    // mistake for a real receipt ever leaves a printer.
    return (200, {'queued': false, 'simulated': true});
  }

  return null;
}

(int, Object?) _checkout(SandboxShop shop, SandboxRequest request) {
  final lines = <({int variantId, double quantity, double? unitPrice})>[];
  for (final row in request.rows('lines')) {
    final id = _variantOf(row);
    if (id == null) {
      continue;
    }
    lines.add((
      variantId: id,
      quantity: request.money(row['quantity']),
      unitPrice: row.containsKey('unit_price')
          ? request.money(row['unit_price'])
          : null,
    ));
  }
  if (lines.isEmpty) {
    return (400, {'detail': 'السلة فارغة'});
  }

  final payments = <SandboxPayment>[
    for (final payment in request.rows('payments'))
      SandboxPayment(
        method: payment['method']?.toString() ?? 'cash',
        amount: request.money(payment['amount']),
      ),
  ];

  final order = shop.recordSale(
    lines: lines,
    payments: payments,
    saleType: request.body['sale_type']?.toString() ?? 'standard',
    customerId: request.id('customer'),
    extraDiscountAmount: request.money(request.body['extra_discount_amount']),
  );
  return (201, orderJson(order));
}

double _subtotal(SandboxShop shop, SandboxRequest request, String key) {
  var subtotal = 0.0;
  for (final row in request.rows(key)) {
    final id = _variantOf(row);
    final variant = id == null ? null : shop.variantById(id);
    if (variant == null) {
      continue;
    }
    subtotal += variant.unitPrice * request.money(row['quantity']);
  }
  return subtotal;
}

/// The cart posts a variant under several names depending on the call site.
int? _variantOf(Map<String, Object?> row) => int.tryParse(
  (row['product_variant'] ?? row['variant'] ?? row['id'])?.toString() ?? '',
);
