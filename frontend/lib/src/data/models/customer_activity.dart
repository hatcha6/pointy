import 'sale_order.dart';

class CustomerSalesSummary {
  const CustomerSalesSummary({
    required this.customerId,
    required this.invoiceCount,
    required this.paidInvoiceCount,
    required this.voidInvoiceCount,
    required this.returnCount,
    required this.voidCount,
    required this.refundCount,
    required this.exchangeCount,
    required this.totalInvoiced,
    required this.returnTotal,
    required this.voidTotal,
    required this.refundTotal,
    required this.exchangeTotal,
    required this.netSales,
    this.outstandingBalance = 0,
    this.quotationCount = 0,
    this.lastInvoiceAt,
    this.representativePaymentId,
  });

  final int customerId;
  final int invoiceCount;
  final int paidInvoiceCount;
  final int voidInvoiceCount;
  final int returnCount;
  final int voidCount;
  final int refundCount;
  final int exchangeCount;
  final double totalInvoiced;
  final double returnTotal;
  final double voidTotal;
  final double refundTotal;
  final double exchangeTotal;
  final double netSales;

  /// Total still owed across the customer's open (credit) debt invoices.
  final double outstandingBalance;

  /// Number of outstanding price quotations issued to this customer.
  final int quotationCount;
  final DateTime? lastInvoiceAt;

  /// On a record-payment response, the oldest allocated payment's id — used to
  /// print/audit a proof-of-payment slip for the whole collection. Null on a
  /// plain sales-summary fetch.
  final int? representativePaymentId;

  factory CustomerSalesSummary.empty(int customerId) {
    return CustomerSalesSummary(
      customerId: customerId,
      invoiceCount: 0,
      paidInvoiceCount: 0,
      voidInvoiceCount: 0,
      returnCount: 0,
      voidCount: 0,
      refundCount: 0,
      exchangeCount: 0,
      totalInvoiced: 0,
      returnTotal: 0,
      voidTotal: 0,
      refundTotal: 0,
      exchangeTotal: 0,
      netSales: 0,
    );
  }

  factory CustomerSalesSummary.fromJson(Map<String, Object?> json) {
    return CustomerSalesSummary(
      customerId: _intFromJson(json['customer']),
      invoiceCount: _intFromJson(json['invoice_count']),
      paidInvoiceCount: _intFromJson(json['paid_invoice_count']),
      voidInvoiceCount: _intFromJson(json['void_invoice_count']),
      returnCount: _intFromJson(json['return_count']),
      voidCount: _intFromJson(json['void_count']),
      refundCount: _intFromJson(json['refund_count']),
      exchangeCount: _intFromJson(json['exchange_count']),
      totalInvoiced: _moneyFromJson(json['total_invoiced']),
      returnTotal: _moneyFromJson(json['return_total']),
      voidTotal: _moneyFromJson(json['void_total']),
      refundTotal: _moneyFromJson(json['refund_total']),
      exchangeTotal: _moneyFromJson(json['exchange_total']),
      netSales: _moneyFromJson(json['net_sales']),
      outstandingBalance: _moneyFromJson(json['outstanding_balance']),
      quotationCount: _intFromJson(json['quotation_count']),
      lastInvoiceAt: _dateTimeFromJson(json['last_invoice_at']),
      representativePaymentId: json['payment'] is Map<String, Object?>
          ? _intFromJson((json['payment'] as Map<String, Object?>)['id'])
          : null,
    );
  }
}

class CustomerAdjustmentHistoryPage {
  const CustomerAdjustmentHistoryPage({
    required this.entries,
    required this.hasMore,
  });

  final List<CustomerAdjustmentHistoryEntry> entries;
  final bool hasMore;

  factory CustomerAdjustmentHistoryPage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = (decoded['results'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(CustomerAdjustmentHistoryEntry.fromJson)
          .toList(growable: false);
      return CustomerAdjustmentHistoryPage(
        entries: results,
        hasMore: decoded['next'] != null,
      );
    }
    if (decoded is List<Object?>) {
      return CustomerAdjustmentHistoryPage(
        entries: decoded
            .whereType<Map<String, Object?>>()
            .map(CustomerAdjustmentHistoryEntry.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const CustomerAdjustmentHistoryPage(entries: [], hasMore: false);
  }
}

enum CustomerAdjustmentType {
  returnItems('return'),
  voidOrder('void'),
  exchange('exchange'),
  refund('refund'),
  unknown('');

  const CustomerAdjustmentType(this.apiValue);

  final String apiValue;

  static CustomerAdjustmentType fromApi(Object? value) {
    return CustomerAdjustmentType.values.firstWhere(
      (type) => type.apiValue == value?.toString(),
      orElse: () => CustomerAdjustmentType.unknown,
    );
  }
}

class CustomerAdjustmentHistoryEntry {
  const CustomerAdjustmentHistoryEntry({
    required this.id,
    required this.orderId,
    required this.receiptNumber,
    required this.customerId,
    required this.registerSessionId,
    required this.registerSessionNumber,
    required this.type,
    required this.amount,
    required this.refundMethod,
    required this.reason,
    required this.createdByUsername,
    required this.lines,
    this.createdAt,
  });

  final int id;
  final int orderId;
  final String receiptNumber;
  final int customerId;
  final int registerSessionId;
  final String registerSessionNumber;
  final CustomerAdjustmentType type;
  final double amount;
  final PaymentMethod refundMethod;
  final String reason;
  final String createdByUsername;
  final List<CustomerAdjustmentHistoryLine> lines;
  final DateTime? createdAt;

  factory CustomerAdjustmentHistoryEntry.fromJson(Map<String, Object?> json) {
    return CustomerAdjustmentHistoryEntry(
      id: _intFromJson(json['id']),
      orderId: _intFromJson(json['order']),
      receiptNumber: json['receipt_number']?.toString() ?? '',
      customerId: _intFromJson(json['customer']),
      registerSessionId: _intFromJson(json['register_session']),
      registerSessionNumber: json['register_session_number']?.toString() ?? '',
      type: CustomerAdjustmentType.fromApi(json['adjustment_type']),
      amount: _moneyFromJson(json['amount']),
      refundMethod: PaymentMethod.fromApiValue(json['refund_method']),
      reason: json['reason']?.toString() ?? '',
      createdByUsername: json['created_by_username']?.toString() ?? '',
      lines: _listFromJson(json['lines'])
          .whereType<Map<String, Object?>>()
          .map(CustomerAdjustmentHistoryLine.fromJson)
          .toList(growable: false),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class CustomerAdjustmentHistoryLine {
  const CustomerAdjustmentHistoryLine({
    required this.id,
    required this.orderLineId,
    required this.productId,
    required this.variantId,
    required this.productName,
    required this.variantName,
    required this.quantity,
    required this.unitPrice,
    required this.discountTotal,
    required this.lineTotal,
  });

  final int id;
  final int orderLineId;
  final int productId;
  final int variantId;
  final String productName;
  final String variantName;
  final int quantity;
  final double unitPrice;
  final double discountTotal;
  final double lineTotal;

  factory CustomerAdjustmentHistoryLine.fromJson(Map<String, Object?> json) {
    return CustomerAdjustmentHistoryLine(
      id: _intFromJson(json['id']),
      orderLineId: _intFromJson(json['order_line']),
      productId: _intFromJson(json['product']),
      variantId: _intFromJson(json['variant']),
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      quantity: _intFromJson(json['quantity']),
      unitPrice: _moneyFromJson(json['unit_price']),
      discountTotal: _moneyFromJson(json['discount_total']),
      lineTotal: _moneyFromJson(json['line_total']),
    );
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _moneyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

List<Object?> _listFromJson(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  return const [];
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
