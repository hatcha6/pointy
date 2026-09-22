/// Turns sandbox state into the JSON the app's real serializers parse.
///
/// Deliberately separate from [SandboxShop]: the shop models a shop, this
/// models the API's wire format. When the API contract changes, this is the
/// file that changes — and a lesson breaking in CI is how we find out.
library;

import 'sandbox_shop.dart';

String money(double value) => value.toStringAsFixed(2);

String stamp(DateTime value) => value.toUtc().toIso8601String();

Map<String, Object?> variantJson(
  SandboxProduct product,
  SandboxVariant variant, {
  bool includeProductDetail = false,
}) {
  return {
    'id': variant.id,
    'product': product.id,
    'product_name': product.name,
    'name': variant.name,
    'display_name': variant.name,
    'full_name': variant.name.isEmpty
        ? product.name
        : '${product.name} — ${variant.name}',
    'sku': variant.sku,
    'barcode': variant.barcode,
    'unit_price': money(variant.unitPrice),
    'is_active': true,
    'is_default': variant.isDefault,
    'tracks_expiry': false,
    'is_service': product.isService,
    'is_prepared': product.isPrepared,
    'unit': product.unit,
    'quantity_on_hand': money(variant.stock),
    'option_values': const <Object?>[],
    if (includeProductDetail) 'product_detail': productJson(product),
  };
}

Map<String, Object?> productJson(SandboxProduct product) {
  return {
    'id': product.id,
    'name': product.name,
    'description': '',
    'is_active': true,
    'is_archived': false,
    'tracks_expiry': false,
    'is_service': product.isService,
    'is_prepared': product.isPrepared,
    'unit': product.unit,
    'quantity_on_hand': money(product.quantityOnHand),
    'popularity': 0,
    'categories': [
      for (final id in product.categoryIds) {'id': id, 'name': 'فئة $id'},
    ],
    'variant_options': const <Object?>[],
    'modifier_groups': const <Object?>[],
    // Every code that scans to this product, one row per packaging unit. This
    // is what a "multiple barcodes" lesson is teaching the learner to build.
    'units': [
      for (final variant in product.variants)
        for (final (index, code) in variant.extraBarcodes.indexed)
          {
            'id': variant.id * 100 + index,
            'product': product.id,
            'name': product.unit,
            'unit_factor': '1.000',
            'is_base': false,
            'barcodes': [
              {'id': variant.id * 100 + index, 'barcode': code},
            ],
          },
    ],
    'default_variant': variantJson(product, product.defaultVariant),
    'variants': [
      for (final variant in product.variants) variantJson(product, variant),
    ],
  };
}

Map<String, Object?> sessionJson(SandboxRegisterSession session) {
  return {
    'id': session.id,
    'session_number': session.sessionNumber,
    'status': session.status,
    'owner_name': session.ownerName,
    'opening_cash': money(session.openingCash),
    'closing_cash': session.closingCash == null
        ? null
        : money(session.closingCash!),
    'count_025': 0,
    'count_050': 0,
    'count_075': 0,
    'count_100': 0,
    'cash_sales_total': money(session.cashSalesTotal),
    'pay_in_total': money(session.payInTotal),
    'pay_out_total': money(session.payOutTotal),
    'cash_refund_total': money(session.cashRefundTotal),
    'expected_cash': money(session.expectedCash),
    'denomination_total': money(0),
    'cash_variance': session.closingCash == null
        ? null
        : money(session.closingCash! - session.expectedCash),
    'has_cash_variance':
        session.closingCash != null &&
        (session.closingCash! - session.expectedCash).abs() > 0.001,
    'opened_at': stamp(session.openedAt),
    'closed_at': session.closedAt == null ? null : stamp(session.closedAt!),
    'created_at': stamp(session.openedAt),
    'updated_at': stamp(DateTime.now()),
  };
}

Map<String, Object?> orderJson(SandboxOrder order) {
  return {
    'id': order.id,
    'receipt_number': order.receiptNumber,
    'status': 'completed',
    'doc_status': 'submitted',
    'sale_type': order.saleType,
    'register_session': order.sessionId,
    'register_session_number': order.sessionNumber,
    'cashier': order.cashierId,
    'cashier_name': order.cashierName,
    'customer': order.customerId,
    'customer_name': order.customerName,
    'created_at': stamp(order.createdAt),
    'subtotal': money(order.subtotal),
    'discount_total': money(order.discountTotal),
    'extra_discount_amount': money(order.extraDiscountAmount),
    'total': money(order.total),
    'paid_total': money(order.paid),
    'balance_due': money(order.balanceDue),
    'lines': [
      for (final line in order.lines)
        {
          'id': line.variantId,
          'product_variant': line.variantId,
          'product_name': line.productName,
          'variant_name': line.variantName,
          'sku': line.sku,
          'quantity': money(line.quantity),
          'unit_price': money(line.unitPrice),
          'line_subtotal': money(line.subtotal),
          'discount_total': money(line.discountTotal),
          'line_total': money(line.total),
          'returned_quantity': money(line.returnedQuantity),
        },
    ],
    'payments': [
      for (final (index, payment) in order.payments.indexed)
        {
          'id': index + 1,
          'method': payment.method,
          'amount': money(payment.amount),
        },
    ],
  };
}

Map<String, Object?> customerJson(SandboxContact contact) {
  return {
    'id': contact.id,
    'customer_number': 'C${contact.id}',
    'full_name': contact.name,
    'phone': contact.phone,
    'email': '',
    'gender': '',
    'notes': '',
    'is_active': true,
    'is_auto_created': false,
    'card_count': 0,
    'marketing_consent': false,
    'credit_limit_policy': 'shop_default',
    'payment_terms_policy': 'shop_default',
    'outstanding_balance': money(contact.balance),
  };
}

Map<String, Object?> supplierJson(SandboxContact contact) {
  return {
    'id': contact.id,
    'name': contact.name,
    'contact_name': '',
    'phone': contact.phone,
    'email': '',
    'address': '',
    'notes': '',
    'is_active': true,
    'payable_balance': money(contact.balance),
    'credit_balance': money(0),
    'net_balance': money(contact.balance),
    'total_bought': money(0),
    'purchase_count': 0,
  };
}

Map<String, Object?> customerSalesSummaryJson(SandboxContact contact) {
  return {
    'customer': contact.id,
    'invoice_count': 0,
    'paid_invoice_count': 0,
    'void_invoice_count': 0,
    'return_count': 0,
    'void_count': 0,
    'refund_count': 0,
    'exchange_count': 0,
    'total_invoiced': money(0),
    'return_total': money(0),
    'void_total': money(0),
    'refund_total': money(0),
    'exchange_total': money(0),
    'net_sales': money(0),
    'outstanding_balance': money(contact.balance),
    'quotation_count': 0,
  };
}

Map<String, Object?> purchaseOrderJson(
  SandboxPurchaseOrder order, {
  bool includeLines = true,
}) {
  return {
    'id': order.id,
    'reference': order.reference,
    'order_number': order.reference,
    'status': order.status,
    'doc_status': order.status == 'draft' ? 'draft' : 'submitted',
    'supplier': order.supplierId,
    'supplier_name': order.supplierName,
    'created_at': stamp(order.createdAt),
    'ordered_at': stamp(order.createdAt),
    'expected_at': null,
    'subtotal': money(order.total),
    'discount_total': money(0),
    'total': money(order.total),
    'total_cost': money(order.total),
    'paid_total': money(order.paidTotal),
    'balance_due': money(order.balanceDue),
    'currency': 'LYD',
    'notes': '',
    if (includeLines)
      // §"list row is not a document": the list serializer drops lines on the
      // real API, and a details surface re-fetches. The practice shop keeps the
      // same split so a lesson cannot come to depend on lines it would not get.
      'lines': [
        for (final line in order.lines)
          {
            // The line's id is its variant's id. Receiving posts back
            // `purchase_line`, and one id for both ends means a received
            // quantity always finds the stock it belongs to.
            'id': line.variantId,
            // `variant`/`variant_sku`, not `product_variant`/`sku`: the order
            // serializer is not the cart serializer, and reading the wrong key
            // leaves the receive dialog with unnamed lines.
            'variant': line.variantId,
            'product_variant': line.variantId,
            'product': line.variantId,
            'product_name': line.productName,
            'variant_name': '',
            'variant_sku': line.sku,
            'quantity': money(line.quantity),
            'received_quantity': money(line.receivedQuantity),
            'open_quantity': money(line.quantity - line.receivedQuantity),
            'damaged_quantity': money(0),
            'rejected_quantity': money(0),
            'unit_cost': money(line.unitCost),
            'line_total': money(line.total),
          },
      ],
  };
}

Map<String, Object?> userJson(SandboxShop shop) {
  return {
    'id': shop.cashierId,
    'username': shop.cashierName,
    'first_name': shop.cashierName,
    'last_name': '',
    'display_name': shop.cashierName,
    'role': shop.cashierRole,
    'is_active': true,
    // The practice shop hands out exactly the permissions the lessons need; a
    // learner must not discover screens their real account cannot open.
    'permissions': shop.cashierPermissions,
    'ai_available': false,
    'allow_cashier_customer_access': true,
    'surveillance_enabled': false,
  };
}

Map<String, Object?> shopSettingsJson(SandboxShop shop) {
  return {
    'shop_name': shop.shopName,
    'receipt_header': shop.shopName,
    'receipt_footer': '',
    'enable_online_invoices': false,
    'require_opening_cash': shop.requireOpeningCash,
    'auto_print_receipts': false,
    'allow_overselling': false,
    'low_stock_threshold': 5,
    'cashier_return_window_hours': 48,
    'enable_cash_payments': true,
    'enable_card_payments': true,
    'enable_transfer_payments': true,
    'require_card_payment_receipt': false,
    'trusted_card_terminal_ids': const <String>[],
    'card_commission_percent': '0.00',
    'transfer_commission_percent': '0.00',
    'enable_credit_sales': true,
    'enable_quotations': true,
    'require_customer_for_credit': true,
    'allow_cashier_customer_access': true,
    'enforce_customer_credit_limits': false,
  };
}
