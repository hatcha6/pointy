import 'sale_order.dart';

/// Why the returns-desk search listed a sold line.
enum ReturnSearchMatch {
  barcode('barcode'),
  sku('sku'),
  serial('serial'),
  name('name'),
  unknown('');

  const ReturnSearchMatch(this.apiValue);

  final String apiValue;

  static ReturnSearchMatch fromApiValue(Object? value) {
    final text = value?.toString() ?? '';
    return ReturnSearchMatch.values.firstWhere(
      (match) => match.apiValue == text && match != unknown,
      orElse: () => unknown,
    );
  }
}

/// One sold line the returns desk found by its goods (`orders/return-search/`):
/// still returnable, sold inside the shop's return window. Enough to tell the
/// customer's purchase apart from the others and open the invoice it is on.
class ReturnSearchLine {
  const ReturnSearchLine({
    required this.id,
    required this.orderId,
    required this.receiptNumber,
    required this.soldAt,
    required this.customerName,
    required this.cashierName,
    required this.productId,
    required this.productName,
    required this.variantName,
    required this.unitLabel,
    required this.quantity,
    required this.returnedQuantity,
    required this.returnableQuantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.matchedBy,
    required this.matchedCode,
  });

  factory ReturnSearchLine.fromJson(Map<String, Object?> json) {
    return ReturnSearchLine(
      id: _int(json['id']),
      orderId: _int(json['order']),
      receiptNumber: json['receipt_number']?.toString() ?? '',
      soldAt: DateTime.tryParse(json['sold_at']?.toString() ?? '')?.toLocal(),
      customerName: json['customer_name']?.toString() ?? '',
      cashierName: json['cashier_name']?.toString() ?? '',
      productId: _int(json['product']),
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      unitLabel: json['unit_label']?.toString() ?? '',
      quantity: _double(json['quantity']),
      returnedQuantity: _double(json['returned_quantity']),
      returnableQuantity: _double(json['returnable_quantity']),
      unitPrice: _double(json['unit_price']),
      lineTotal: _double(json['line_total']),
      matchedBy: ReturnSearchMatch.fromApiValue(json['matched_by']),
      matchedCode: json['matched_code']?.toString() ?? '',
    );
  }

  final int id;
  final int orderId;
  final String receiptNumber;
  final DateTime? soldAt;
  final String customerName;
  final String cashierName;
  final int productId;
  final String productName;
  final String variantName;
  final String unitLabel;
  final double quantity;
  final double returnedQuantity;
  final double returnableQuantity;
  final double unitPrice;
  final double lineTotal;
  final ReturnSearchMatch matchedBy;

  /// The code that named this line when it is not obvious from the line
  /// itself — a handset's IMEI.
  final String matchedCode;

  /// «أرز - 5 كغ» when the variant has a name of its own, else the product's.
  String get displayName {
    if (variantName.isNotEmpty &&
        productName.isNotEmpty &&
        variantName != productName) {
      return '$productName - $variantName';
    }
    return productName.isNotEmpty ? productName : variantName;
  }
}

/// What one returns-desk search found.
///
/// [order] set means one invoice matched exactly (a whole receipt number or
/// the receipt's QR link) — open it. Otherwise [invoices] (receipt-number
/// tails, a customer's phone) and [lines] (goods sold inside the return
/// window) are the choices.
class ReturnSearchResult {
  const ReturnSearchResult({
    this.order,
    this.invoices = const [],
    this.lines = const [],
    this.linesTruncated = false,
    required this.windowHours,
    this.windowStartsAt,
  });

  factory ReturnSearchResult.fromJson(Map<String, Object?> json) {
    final order = json['order'];
    return ReturnSearchResult(
      order: order is Map<String, Object?> ? SaleOrder.fromJson(order) : null,
      invoices: _maps(json['invoices']).map(SaleOrder.fromJson).toList(),
      lines: _maps(json['lines']).map(ReturnSearchLine.fromJson).toList(),
      linesTruncated: json['lines_truncated'] == true,
      windowHours: _int(json['window_hours']),
      windowStartsAt: DateTime.tryParse(
        json['window_starts_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }

  final SaleOrder? order;
  final List<SaleOrder> invoices;
  final List<ReturnSearchLine> lines;

  /// More lines matched than were sent; the cashier should narrow the search.
  final bool linesTruncated;

  /// The shop's return window (`cashier_return_window_hours`). Zero means goods
  /// searches find nothing and only a receipt number can open an invoice.
  final int windowHours;
  final DateTime? windowStartsAt;

  bool get isEmpty => order == null && invoices.isEmpty && lines.isEmpty;
}

Iterable<Map<String, Object?>> _maps(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  return value.whereType<Map<String, Object?>>();
}

int _int(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _double(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
